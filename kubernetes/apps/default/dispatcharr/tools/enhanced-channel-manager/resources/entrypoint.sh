#!/bin/sh
set -e

ECM_PORT="${ECM_PORT:-6100}"
ECM_HTTPS_PORT="${ECM_HTTPS_PORT:-6143}"
ECM_LIMIT_CONCURRENCY="${ECM_LIMIT_CONCURRENCY:-50}"
ECM_TIMEOUT_KEEP_ALIVE="${ECM_TIMEOUT_KEEP_ALIVE:-30}"

print_info() {
  printf '%s\n' "-> $1"
}

print_success() {
  printf '%s\n' "OK: $1"
}

print_warning() {
  printf '%s\n' "WARN: $1"
}

print_error() {
  printf '%s\n' "ERROR: $1" >&2
}

check_python() {
  print_info "Checking Python environment"

  if command -v python3 >/dev/null 2>&1; then
    print_success "Python found"
  else
    print_error "Python 3 not found"
    return 1
  fi

  if python3 -c "import fastapi, uvicorn" >/dev/null 2>&1; then
    print_success "FastAPI and Uvicorn available"
  else
    print_error "Required Python packages missing"
    return 1
  fi
}

check_filesystem() {
  print_info "Checking filesystem"

  if [ ! -d /config ]; then
    print_error "/config is missing"
    return 1
  fi

  mkdir -p /config/tls /config/uploads/logos

  if touch /config/.write_test 2>/dev/null; then
    rm -f /config/.write_test
    print_success "/config is writable"
  else
    print_error "/config is not writable"
    return 1
  fi
}

check_application() {
  print_info "Checking application modules"

  if [ ! -f /app/main.py ]; then
    print_error "Application entry point (main.py) not found"
    return 1
  fi

  cd /app
  if python3 -c "import main" >/dev/null 2>&1; then
    print_success "Application module loads successfully"
  else
    print_error "Application module failed to load"
    python3 -c "import main"
    return 1
  fi
}

check_tls_config() {
  TLS_CONFIG="/config/tls_settings.json"
  TLS_CERT="/config/tls/cert.pem"
  TLS_KEY="/config/tls/key.pem"

  if [ ! -f "$TLS_CONFIG" ]; then
    print_info "TLS not configured"
    return 0
  fi

  TLS_ENABLED=$(python3 -c "import json; print(json.load(open('$TLS_CONFIG')).get('enabled', False))" 2>/dev/null || echo "False")
  HTTPS_PORT=$(python3 -c "import json; print(json.load(open('$TLS_CONFIG')).get('https_port', $ECM_HTTPS_PORT))" 2>/dev/null || echo "$ECM_HTTPS_PORT")

  if [ "$TLS_ENABLED" = "True" ] && [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
    print_success "TLS enabled with valid certificates"
    print_info "HTTPS will start on port $HTTPS_PORT"
  elif [ "$TLS_ENABLED" = "True" ]; then
    print_warning "TLS enabled but certificates not found"
  else
    print_info "TLS not enabled"
  fi
}

check_python
check_filesystem
check_application
check_tls_config

print_info "Starting Enhanced Channel Manager on :$ECM_PORT"
cd /app
exec uvicorn main:app \
  --host 0.0.0.0 \
  --port "$ECM_PORT" \
  --limit-concurrency "$ECM_LIMIT_CONCURRENCY" \
  --timeout-keep-alive "$ECM_TIMEOUT_KEEP_ALIVE"
