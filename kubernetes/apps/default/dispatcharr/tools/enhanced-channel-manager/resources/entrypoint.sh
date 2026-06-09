#!/bin/sh
set -e

# Default ports
ECM_PORT=${ECM_PORT:-6100}
ECM_HTTPS_PORT=${ECM_HTTPS_PORT:-6143}

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Unicode symbols
CHECK_MARK="✓"
CROSS_MARK="✗"
ARROW="→"

print_header() {
    echo ""
    echo "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo "${BLUE}  Enhanced Channel Manager - Startup Preflight Checks${NC}"
    echo "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_success() {
    echo "${GREEN}${CHECK_MARK}${NC} $1"
}

print_error() {
    echo "${RED}${CROSS_MARK}${NC} $1"
}

print_warning() {
    echo "${YELLOW}!${NC} $1"
}

print_info() {
    echo "${BLUE}${ARROW}${NC} $1"
}

# Kubernetes already sets uid/gid via runAsUser, runAsGroup, and fsGroup.
# The upstream setup_user() mutates passwd/group entries and requires root,
# so it is intentionally omitted here.

check_python() {
    print_info "Checking Python environment..."

    if command -v python3 >/dev/null 2>&1; then
        PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
        print_success "Python ${PYTHON_VERSION} found"
    else
        print_error "Python 3 not found"
        return 1
    fi

    if python3 -c "import fastapi, uvicorn" 2>/dev/null; then
        print_success "FastAPI and Uvicorn available"
    else
        print_error "Required Python packages missing"
        return 1
    fi

    return 0
}

check_filesystem() {
    print_info "Checking filesystem..."

    if [ -d "/config" ]; then
        print_success "Config directory exists"
    else
        print_warning "Config directory missing, creating..."
        mkdir -p /config || {
            print_error "Failed to create config directory"
            return 1
        }
        print_success "Config directory created"
    fi

    # Ensure subdirectories exist (volume mounts lose Dockerfile-created dirs)
    mkdir -p /config/tls /config/uploads/logos

    # Upstream fixes ownership and mode here. Under runAsNonRoot we cannot chown,
    # and chmod may fail depending on the volume backend, so only verify writability.
    if touch /config/.write_test 2>/dev/null; then
        rm -f /config/.write_test
        print_success "Config directory is writable"
    else
        print_error "Config directory is not writable"
        return 1
    fi

    if [ -d "/app/static" ]; then
        print_success "Frontend build found"
    else
        print_warning "Frontend build directory not found"
    fi

    return 0
}

check_network() {
    print_info "Checking network configuration..."

    if ! netstat -tuln 2>/dev/null | grep -q ":${ECM_PORT} "; then
        print_success "Port ${ECM_PORT} (HTTP) is available"
    else
        print_warning "Port ${ECM_PORT} (HTTP) is already in use"
    fi

    if ! netstat -tuln 2>/dev/null | grep -q ":${ECM_HTTPS_PORT} "; then
        print_success "Port ${ECM_HTTPS_PORT} (HTTPS) is available"
    else
        print_warning "Port ${ECM_HTTPS_PORT} (HTTPS) is already in use"
    fi

    return 0
}

check_application() {
    print_info "Checking application modules..."

    if [ -f "/app/main.py" ]; then
        print_success "Application entry point found"
    else
        print_error "Application entry point (main.py) not found"
        return 1
    fi

    cd /app
    if python3 -c "import main" 2>/dev/null; then
        print_success "Application module loads successfully"
    else
        print_error "Application module failed to load"
        echo ""
        echo "${RED}Full traceback:${NC}"
        python3 -c "import main" 2>&1
        echo ""
        return 1
    fi

    return 0
}

check_tls_config() {
    TLS_CONFIG="/config/tls_settings.json"
    TLS_CERT="/config/tls/cert.pem"
    TLS_KEY="/config/tls/key.pem"

    if [ -f "$TLS_CONFIG" ]; then
        TLS_ENABLED=$(python3 -c "import json; print(json.load(open('$TLS_CONFIG')).get('enabled', False))" 2>/dev/null || echo "False")
        HTTPS_PORT=$(python3 -c "import json; print(json.load(open('$TLS_CONFIG')).get('https_port', $ECM_HTTPS_PORT))" 2>/dev/null || echo "$ECM_HTTPS_PORT")

        if [ "$TLS_ENABLED" = "True" ] && [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
            print_success "TLS enabled with valid certificates"
            print_info "HTTPS will start on port $HTTPS_PORT (managed by application)"
        elif [ "$TLS_ENABLED" = "True" ]; then
            print_warning "TLS enabled but certificates not found"
        else
            print_info "TLS not enabled"
        fi
    else
        print_info "TLS not configured"
    fi
}

print_startup_info() {
    echo ""
    echo "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo "${GREEN}  All preflight checks passed!${NC}"
    echo "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    print_info "Starting Enhanced Channel Manager..."
    print_info "HTTP Server: http://0.0.0.0:${ECM_PORT}"
    print_info "HTTPS Server: Managed by application (if TLS enabled)"
    print_info "Health Check: http://0.0.0.0:${ECM_PORT}/api/health"
    echo ""
}

run_preflight_checks() {
    print_header

    FAILED=0

    check_python || FAILED=1
    check_filesystem || FAILED=1
    check_network || FAILED=1
    check_application || FAILED=1

    if [ $FAILED -eq 1 ]; then
        echo ""
        print_error "Preflight checks failed! See errors above."
        echo ""
        exit 1
    fi

    print_startup_info
}

run_preflight_checks
check_tls_config

cd /app
ECM_LIMIT_CONCURRENCY=${ECM_LIMIT_CONCURRENCY:-50}
ECM_TIMEOUT_KEEP_ALIVE=${ECM_TIMEOUT_KEEP_ALIVE:-30}
exec uvicorn main:app \
    --host 0.0.0.0 \
    --port ${ECM_PORT} \
    --limit-concurrency ${ECM_LIMIT_CONCURRENCY} \
    --timeout-keep-alive ${ECM_TIMEOUT_KEEP_ALIVE}
