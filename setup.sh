#!/bin/bash
set -Eeuo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${BLUE}=== $* ===${NC}"; }

# Configuration
INSTALL_DIR="$(cd "${1:-.}" && pwd)"  # Convert to absolute path
PDF_FILE="${2:-}"
REPO_URL="https://github.com/georgia-tech-db/TokenSmith.git"
REPO_BRANCH="main"
TOKENSMITH_DIR=""  # Will be set during clone
AUTO_CHAT=false  # Don't auto-launch chat to avoid EOF errors

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-chat) AUTO_CHAT=false; shift ;;
    --help) HELP_FLAG=true; shift ;;
    *) shift ;;
  esac
done

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

check_requirements() {
    log_step "Checking system requirements"
    
    # Check Conda
    if ! command -v conda &> /dev/null; then
        log_error "Conda/Miniconda not found"
        echo "Please install Miniconda from: https://docs.conda.io/projects/miniconda/en/latest/"
        exit 1
    fi
    log_info "Conda found: $(conda --version)"
    
    # Check Git
    if ! command -v git &> /dev/null; then
        log_error "Git not found"
        echo "Please install Git"
        exit 1
    fi
    log_info "Git found: $(git --version)"
    
    # Check system requirements
    OS="$(uname -s)"
    log_info "Detected OS: $OS"
    
    if [[ "$OS" == "Darwin" ]]; then
        if ! command -v xcode-select &> /dev/null; then
            log_warn "Xcode Command Line Tools may be needed on macOS"
        fi
    fi
}

clone_repository() {
    log_step "Detecting TokenSmith repository"
    
    # Check if current directory is already a TokenSmith repository
    if [[ -f "Makefile" ]] && [[ -d "src" ]] && [[ -d "config" ]] && [[ -f "pyproject.toml" ]]; then
        log_info "Current directory is already TokenSmith!"
        TOKENSMITH_DIR="$(pwd)"
        log_info "Using existing repository at: $TOKENSMITH_DIR"
        return
    fi
    
    # Check if INSTALL_DIR contains TokenSmith
    local clone_target="$INSTALL_DIR/TokenSmith"
    
    if [[ -f "$clone_target/Makefile" ]] && [[ -d "$clone_target/src" ]]; then
        log_warn "TokenSmith directory already exists at: $clone_target"
        TOKENSMITH_DIR="$clone_target"
        log_info "Using existing repository"
        return
    fi
    
    # Need to clone
    log_step "Cloning TokenSmith repository"
    log_info "Cloning from: $REPO_URL"
    log_info "Target directory: $clone_target"
    
    # Create parent directory if it doesn't exist
    mkdir -p "$INSTALL_DIR"
    
    # Run git clone
    if git clone --branch "$REPO_BRANCH" "$REPO_URL" "$clone_target" > /tmp/git_clone.log 2>&1; then
        TOKENSMITH_DIR="$clone_target"
        log_info "Repository cloned successfully"
    else
        log_error "Failed to clone repository"
        log_error "Error details:"
        if [[ -f /tmp/git_clone.log ]]; then
            tail -20 /tmp/git_clone.log
        fi
        exit 1
    fi
    
    # Verify directory exists and has expected structure
    if [[ ! -d "$TOKENSMITH_DIR" ]]; then
        log_error "TokenSmith directory not found at: $TOKENSMITH_DIR"
        ls -la "$INSTALL_DIR" | head -20
        exit 1
    fi
    
    if [[ ! -f "$TOKENSMITH_DIR/Makefile" ]]; then
        log_error "Invalid TokenSmith directory - missing Makefile at: $TOKENSMITH_DIR"
        ls -la "$TOKENSMITH_DIR" | head -20
        exit 1
    fi
    
    log_info "TokenSmith ready at: $TOKENSMITH_DIR"
}

build_environment() {
    log_step "Building TokenSmith environment and dependencies"
    
    cd "$TOKENSMITH_DIR"
    
    if ! conda run -n tokensmith true 2>/dev/null; then
        log_info "Creating new Conda environment..."
        if ! make build > /tmp/tokensmith_build.log 2>&1; then
            log_error "Build failed. See details below:"
            tail -20 /tmp/tokensmith_build.log
            exit 1
        fi
    else
        log_warn "Conda environment 'tokensmith' already exists, skipping rebuild"
    fi
    
    log_info "Environment ready"
}

download_models() {
    log_step "Downloading language models (this may take 10-15 minutes)"
    
    cd "$TOKENSMITH_DIR"
    local models_dir="$(pwd)/models"
    
    # Check if models already exist
    if [[ -f "$models_dir/Qwen3-Embedding-4B-Q5_K_M.gguf" ]] && [[ -f "$models_dir/qwen2.5-3b-instruct-q8_0.gguf" ]]; then
        log_info "✓ Models already present, skipping download"
        return 0
    fi
    
    mkdir -p "$models_dir"
    log_info "Models directory: $models_dir"
    
    # Try to install huggingface-hub
    log_info "Setting up download tools..."
    if conda run -n tokensmith pip install huggingface-hub 2>&1 | grep -q "Successfully installed\|already satisfied"; then
        log_info "✓ Download tools ready"
        
        # Download with Python API
        download_with_hf_hub "$models_dir"
        local result=$?
        
        if [[ $result -eq 0 ]]; then
            return 0
        fi
    else
        log_warn "Could not install huggingface-hub"
    fi
    
    # Fallback: show manual download instructions
    log_error "Automated download failed"
    show_manual_download_links "$models_dir"
    return 1
}

download_with_hf_hub() {
    local models_dir="$1"
    
    # Download embedding model
    if [[ ! -f "$models_dir/Qwen3-Embedding-4B-Q5_K_M.gguf" ]]; then
        log_info "Downloading embedding model (3 GB) - this may take several minutes..."
        
        # Write Python script to temp file
        cat > /tmp/hf_download_embed_script.py << 'PYEOF'
import sys
import os
from huggingface_hub import hf_hub_download

try:
    print("Connecting to Hugging Face...", file=sys.stderr)
    path = hf_hub_download(
        repo_id="Qwen/Qwen3-Embedding-4B-GGUF",
        filename="Qwen3-Embedding-4B-Q5_K_M.gguf",
        local_dir=os.path.expanduser("./models"),
        local_dir_use_symlinks=False,
        resume_download=True
    )
    print(f"Downloaded: {path}", file=sys.stderr)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        
        if ! conda run -n tokensmith python3 /tmp/hf_download_embed_script.py > /tmp/hf_download_embed.log 2>&1; then
            log_error "Failed to download embedding model"
            cat /tmp/hf_download_embed.log >&2
            return 1
        fi
        log_info "✓ Embedding model downloaded"
    else
        log_info "✓ Embedding model already exists"
    fi
    
    # Download generation model
    if [[ ! -f "$models_dir/qwen2.5-3b-instruct-q8_0.gguf" ]]; then
        log_info "Downloading generation model (2 GB) - this may take several minutes..."
        
        # Write Python script to temp file
        cat > /tmp/hf_download_gen_script.py << 'PYEOF'
import sys
import os
from huggingface_hub import hf_hub_download

try:
    print("Connecting to Hugging Face...", file=sys.stderr)
    path = hf_hub_download(
        repo_id="Qwen/qwen2.5-3b-instruct-GGUF",
        filename="qwen2.5-3b-instruct-q8_0.gguf",
        local_dir=os.path.expanduser("./models"),
        local_dir_use_symlinks=False,
        resume_download=True
    )
    print(f"Downloaded: {path}", file=sys.stderr)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        
        if ! conda run -n tokensmith python3 /tmp/hf_download_gen_script.py > /tmp/hf_download_gen.log 2>&1; then
            log_error "Failed to download generation model"
            cat /tmp/hf_download_gen.log >&2
            return 1
        fi
        log_info "✓ Generation model downloaded"
    else
        log_info "✓ Generation model already exists"
    fi
    
    log_info "All models downloaded successfully!"
    return 0
}

show_manual_download_links() {
    local models_dir="$1"
    
    log_error ""
    log_error "If models are still missing, download manually:"
    log_error ""
    log_error "1. Visit Hugging Face and download:"
    log_error "   https://huggingface.co/Qwen/Qwen3-Embedding-4B-GGUF"
    log_error "   Download: Qwen3-Embedding-4B-Q5_K_M.gguf (3 GB)"
    log_error ""
    log_error "   https://huggingface.co/Qwen/qwen2.5-3b-instruct-GGUF"  
    log_error "   Download: qwen2.5-3b-instruct-q8_0.gguf (2 GB)"
    log_error ""
    log_error "2. Place both files in: $models_dir/"
    log_error ""
    log_error "3. Rerun setup: bash setup.sh"
    log_error ""
    log_error "Alternatively, edit config/config.yaml to use different models"
    log_error ""
}

setup_sample_pdf() {
    log_step "Setting up sample document"
    
    # Verify we have a valid TokenSmith directory
    if [[ -z "$TOKENSMITH_DIR" ]] || [[ ! -d "$TOKENSMITH_DIR" ]]; then
        log_error "TokenSmith directory not found or not set: $TOKENSMITH_DIR"
        log_error "Clone may have failed. Check /tmp/git_clone.log for details"
        exit 1
    fi
    
    cd "$TOKENSMITH_DIR"
    
    if [[ -n "$PDF_FILE" && -f "$PDF_FILE" ]]; then
        log_info "Using provided PDF: $PDF_FILE"
        mkdir -p data/chapters
        cp "$PDF_FILE" data/chapters/
        SAMPLE_PDF="$PDF_FILE"
    else
        log_info "No PDF provided, creating sample markdown"
        mkdir -p data
        
        # Create a simple sample markdown for demonstration
        # Note: Headings must follow format "## N" or "## N.M" to be extracted
        cat > data/sample.md << 'EOF'
# Introduction to Databases

## 1 Basic Concepts

### What is a Database?

A database is an organized collection of structured data stored and accessed electronically. It provides efficient mechanisms for storing, retrieving, and managing large amounts of information. Databases are fundamental to modern software systems and applications.

### Key Properties

Databases typically support the following operations:
- Create: Insert new data
- Read: Retrieve existing data
- Update: Modify existing data
- Delete: Remove data

These operations are collectively known as CRUD operations.

### Database Models

The main database models include:
1. Relational Model: Organizes data in tables with rows and columns
2. Document Model: Stores data as JSON-like documents
3. Key-Value Model: Simple key to value mapping
4. Graph Model: Stores data as nodes and relationships

### Advantages of Databases

Databases provide significant advantages:
- Data Persistence: Data survives beyond program execution
- Concurrency Control: Multiple users can access data simultaneously
- Security: Access controls and encryption protect sensitive data
- Scalability: Can handle growing amounts of data
- Reliability: Built-in mechanisms for data backup and recovery

## 2 SQL Fundamentals

### Introduction to SQL

SQL (Structured Query Language) is the standard language for querying relational databases. It provides a declarative approach to data manipulation.

### SELECT Statement

The SELECT statement retrieves data from tables. Basic syntax:

    SELECT column1, column2
    FROM table_name
    WHERE condition;

Example:
    SELECT name, age FROM users WHERE age > 18;

This returns names and ages of all users older than 18.

### Transactions

A transaction is a sequence of database operations that must all succeed or all fail together. Key properties:

- Atomicity: All or nothing execution
- Consistency: Data validity preserved
- Isolation: Transactions don't interfere
- Durability: Committed data persists

### Indexes

Indexes improve query performance by organizing data for faster retrieval. The most common type is the B-tree index, which balances search efficiency with update performance.

EOF
        log_info "Sample markdown created at data/sample.md"
        SAMPLE_PDF="sample"
    fi
}

extract_and_index() {
    log_step "Extracting and indexing documents"
    
    cd "$TOKENSMITH_DIR"
    
    # Quick check that models are in place
    if [[ ! -f "models/Qwen3-Embedding-4B-Q5_K_M.gguf" ]] || [[ ! -f "models/qwen2.5-3b-instruct-q8_0.gguf" ]]; then
        log_error "Model files are missing - download may have failed"
        log_error "Check the model download logs above"
        exit 1
    fi
    
    # First, generate extracted_sections.json from the markdown files in data/
    log_info "Extracting sections from markdown files..."
    conda run -n tokensmith python << 'PYEOF'
import json
import sys
from pathlib import Path
from src.preprocessing.extraction import extract_sections_from_markdown

# Find all markdown files in data/
data_dir = Path("data")
md_files = sorted(data_dir.glob("*.md"))

if not md_files:
    print("ERROR: No markdown files found in data/", file=sys.stderr)
    sys.exit(1)

all_sections = []
for md_file in md_files:
    print(f"Extracting from {md_file}...", file=sys.stderr)
    sections = extract_sections_from_markdown(str(md_file))
    if sections:
        print(f"  Found {len(sections)} sections", file=sys.stderr)
        all_sections.extend(sections)
    else:
        print(f"  No sections found (may not match expected heading format)", file=sys.stderr)

if not all_sections:
    print("WARNING: No sections extracted from any markdown files", file=sys.stderr)
    print("  Headings should follow format: ## 1 (or ## 1.2 or ## 1.2.3)", file=sys.stderr)

output_file = data_dir / "extracted_sections.json"
with open(output_file, 'w') as f:
    json.dump(all_sections, f, indent=2)
print(f"Extracted {len(all_sections)} total sections -> {output_file}", file=sys.stderr)
PYEOF
    if [[ $? -ne 0 ]]; then
        log_warn "Markdown extraction had issues (continuing with indexing anyway)"
    fi
    
    log_info "Running indexing..."
    if ! conda run -n tokensmith python -m src.main index 2>&1 | tail -100; then
        log_error "Indexing failed"
        exit 1
    fi
    
    log_info "Indexing complete"
}

# Removed auto-chat launch to avoid stdin/EOFError issues
# Users should manually run: cd $TOKENSMITH_DIR && conda activate tokensmith && python -m src.main chat

print_summary() {
    log_step "Setup Complete"
    
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  ✅ TokenSmith Setup Completed Successfully!               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Location: $TOKENSMITH_DIR"
    echo ""
    echo "To start the interactive chat CLI:"
    echo "  cd $TOKENSMITH_DIR"
    echo "  conda activate tokensmith"
    echo "  python -m src.main chat"
    echo ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    echo ""
    echo "=========================================="
    echo "  TokenSmith: One-Command Setup"
    echo "=========================================="
    echo ""
    
    # Show help if requested
    if [[ "${HELP_FLAG:-false}" == "true" ]]; then
        echo "Usage: bash setup.sh [FLAGS] [INSTALL_DIR] [PDF_FILE]"
        echo ""
        echo "Flags:"
        echo "  --help       - Show this help message"
        echo ""
        echo "Arguments:"
        echo "  INSTALL_DIR  - Directory to install TokenSmith (default: current directory)"
        echo "  PDF_FILE     - Path to PDF to index (optional, uses sample if not provided)"
        echo ""
        echo "Examples:"
        echo "  # Full automated setup:"
        echo "  bash setup.sh"
        echo ""
        echo "  # Setup with custom directory:"
        echo "  bash setup.sh ~/my-tokensmith"
        echo ""
        echo "  # Setup with custom PDF:"
        echo "  bash setup.sh . textbook.pdf"
        exit 0
    fi
    
    # Execution flow
    check_requirements
    clone_repository
    build_environment
    download_models
    setup_sample_pdf
    extract_and_index
    print_summary
    
    # Since AUTO_CHAT=false by default, setup completes and shows instructions
    # (see print_summary for output above)
}

# Run main
main "$@"
