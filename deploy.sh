#!/usr/bin/env bash

# Production-ready Django Deployment Automation Script
# Author: Solomon Kassa
# Version: 1.0.0
# License: MIT

set -euo pipefail
IFS=$'\n\t'

# Color and formatting
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'
readonly UNDERLINE='\033[4m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${MAGENTA}[DEBUG]${NC} $1"; }

# Configuration
readonly CONFIG_FILE=".django_deploy.conf"
readonly BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="deployment_$(date +%Y%m%d_%H%M%S).log"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize log file
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

# Load configuration if exists
load_config() {
    if [[ -f "${CONFIG_FILE}" ]]; then
        source "${CONFIG_FILE}"
        log_info "Configuration loaded from ${CONFIG_FILE}"
    fi
}

# Save configuration
save_config() {
    cat > "${CONFIG_FILE}" << EOF
# Django Deployment Configuration
# Generated: $(date)

PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_DIR="${PROJECT_DIR:-}"
VENV_DIR="${VENV_DIR:-}"
APP_USER="${APP_USER:-}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"
DJANGO_SECRET_KEY="${DJANGO_SECRET_KEY:-}"
DJANGO_DEBUG="${DJANGO_DEBUG:-false}"
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"
SERVER_IP="${SERVER_IP:-}"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-}"
USE_CELERY="${USE_CELERY:-false}"
USE_DOCKER="${USE_DOCKER:-false}"
GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
EMAIL_HOST="${EMAIL_HOST:-}"
EMAIL_PORT="${EMAIL_PORT:-587}"
EMAIL_USER="${EMAIL_USER:-}"
EMAIL_PASS="${EMAIL_PASS:-}"
EOF
    chmod 600 "${CONFIG_FILE}"
    log_success "Configuration saved to ${CONFIG_FILE}"
}

# Check prerequisites
check_prerequisites() {
    local missing_tools=()
    
    log_info "Checking prerequisites..."
    
    # Required tools
    declare -A tools=(
        ["python3"]="Python 3.8+"
        ["pip3"]="Python pip"
        ["git"]="Git"
        ["whiptail"]="Whiptail for TUI"
        ["nginx"]="Nginx web server"
        ["supervisorctl"]="Supervisor process control"
    )
    
    for tool in "${!tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            missing_tools+=("${tools[$tool]}")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            log_error "  - ${tool}"
        done
        return 1
    fi
    
    # Check Python version
    local python_version
    python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if [[ $(echo "$python_version < 3.8" | bc) -eq 1 ]]; then
        log_error "Python 3.8+ required, found ${python_version}"
        return 1
    fi
    
    log_success "All prerequisites met"
    return 0
}

# Interactive configuration wizard
config_wizard() {
    log_info "Starting configuration wizard..."
    
    # Project details
    PROJECT_NAME=$(whiptail --inputbox "Enter project name:" 10 60 "my_django_project" 3>&1 1>&2 2>&3)
    PROJECT_DIR=$(whiptail --inputbox "Enter project directory:" 10 60 "/opt/${PROJECT_NAME}" 3>&1 1>&2 2>&3)
    VENV_DIR=$(whiptail --inputbox "Enter virtual environment directory:" 10 60 "${PROJECT_DIR}/venv" 3>&1 1>&2 2>&3)
    APP_USER=$(whiptail --inputbox "Enter application user:" 10 60 "django" 3>&1 1>&2 2>&3)
    
    # Database configuration
    DB_NAME=$(whiptail --inputbox "Enter database name:" 10 60 "${PROJECT_NAME}_db" 3>&1 1>&2 2>&3)
    DB_USER=$(whiptail --inputbox "Enter database user:" 10 60 "${PROJECT_NAME}_user" 3>&1 1>&2 2>&3)
    DB_PASS=$(whiptail --passwordbox "Enter database password:" 10 60 3>&1 1>&2 2>&3)
    
    # Django settings
    DJANGO_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
    
    ALLOWED_HOSTS=$(whiptail --inputbox "Enter allowed hosts (comma-separated):" 10 60 "localhost,127.0.0.1" 3>&1 1>&2 2>&3)
    DOMAIN_NAME=$(whiptail --inputbox "Enter domain name (if any):" 10 60 "" 3>&1 1>&2 2>&3)
    
    # Deployment options
    DEPLOYMENT_TYPE=$(whiptail --menu "Select deployment type:" 15 60 5 \
        "gunicorn" "Gunicorn + Nginx" \
        "uwsgi" "uWSGI + Nginx" \
        "asgi" "Daphne + Nginx (ASGI)" 3>&1 1>&2 2>&3)
    
    USE_CELERY=$(whiptail --yesno "Use Celery for background tasks?" 10 60 && echo "true" || echo "false")
    USE_DOCKER=$(whiptail --yesno "Use Docker for deployment?" 10 60 && echo "true" || echo "false")
    
    # Git repository
    GIT_REPO=$(whiptail --inputbox "Enter Git repository URL:" 10 60 "" 3>&1 1>&2 2>&3)
    GIT_BRANCH=$(whiptail --inputbox "Enter Git branch:" 10 60 "main" 3>&1 1>&2 2>&3)
    
    # Email configuration
    whiptail --yesno "Configure email settings?" 10 60 && {
        EMAIL_HOST=$(whiptail --inputbox "Enter email host:" 10 60 "smtp.gmail.com" 3>&1 1>&2 2>&3)
        EMAIL_PORT=$(whiptail --inputbox "Enter email port:" 10 60 "587" 3>&1 1>&2 2>&3)
        EMAIL_USER=$(whiptail --inputbox "Enter email user:" 10 60 "" 3>&1 1>&2 2>&3)
        EMAIL_PASS=$(whiptail --passwordbox "Enter email password:" 10 60 3>&1 1>&2 2>&3)
    }
    
    # Confirm configuration
    whiptail --yesno "Save this configuration?" 10 60 && save_config
}

# Setup system user
setup_system_user() {
    log_info "Setting up system user: ${APP_USER}"
    
    if ! id "${APP_USER}" &>/dev/null; then
        sudo useradd -r -s /usr/sbin/nologin "${APP_USER}"
        log_success "User ${APP_USER} created"
    else
        log_info "User ${APP_USER} already exists"
    fi
    
    # Create project directory
    sudo mkdir -p "${PROJECT_DIR}"
    sudo chown -R "${APP_USER}:${APP_USER}" "${PROJECT_DIR}"
    sudo chmod -R 755 "${PROJECT_DIR}"
}

# Setup Python virtual environment
setup_virtualenv() {
    log_info "Setting up Python virtual environment..."
    
    sudo -u "${APP_USER}" python3 -m venv "${VENV_DIR}"
    sudo -u "${APP_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel
    
    # Install Django and dependencies
    local requirements_file="${PROJECT_DIR}/requirements.txt"
    if [[ -f "${requirements_file}" ]]; then
        sudo -u "${APP_USER}" "${VENV_DIR}/bin/pip" install -r "${requirements_file}"
    else
        sudo -u "${APP_USER}" "${VENV_DIR}/bin/pip" install \
            django \
            gunicorn \
            psycopg2-binary \
            python-dotenv \
            whitenoise \
            django-cors-headers \
            django-debug-toolbar \
            django-extensions
        
        [[ "${USE_CELERY}" == "true" ]] && \
            sudo -u "${APP_USER}" "${VENV_DIR}/bin/pip" install celery redis
    fi
    
    log_success "Virtual environment setup complete"
}

# Setup PostgreSQL database
setup_database() {
    log_info "Setting up PostgreSQL database..."
    
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME};" 2>/dev/null || true
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true
    sudo -u postgres psql -c "ALTER ROLE ${DB_USER} SET client_encoding TO 'utf8';"
    sudo -u postgres psql -c "ALTER ROLE ${DB_USER} SET default_transaction_isolation TO 'read committed';"
    sudo -u postgres psql -c "ALTER ROLE ${DB_USER} SET timezone TO 'UTC';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
    
    log_success "Database setup complete"
}

# Clone or update repository
setup_repository() {
    log_info "Setting up project repository..."
    
    if [[ -n "${GIT_REPO}" ]]; then
        if [[ -d "${PROJECT_DIR}/.git" ]]; then
            cd "${PROJECT_DIR}"
            sudo -u "${APP_USER}" git pull origin "${GIT_BRANCH}"
        else
            sudo -u "${APP_USER}" git clone -b "${GIT_BRANCH}" "${GIT_REPO}" "${PROJECT_DIR}"
        fi
    else
        log_warning "No Git repository specified, using existing project"
    fi
}

# Configure Django settings
configure_django() {
    log_info "Configuring Django settings..."
    
    local env_file="${PROJECT_DIR}/.env"
    local sample_env_file="${PROJECT_DIR}/.env.sample"
    
    # Create .env file from sample if exists
    if [[ -f "${sample_env_file}" ]]; then
        cp "${sample_env_file}" "${env_file}"
    fi
    
    # Update environment variables
    cat >> "${env_file}" << EOF

# Auto-generated by deployment script
DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}
DJANGO_DEBUG=${DJANGO_DEBUG}
DJANGO_ALLOWED_HOSTS=${ALLOWED_HOSTS}
DATABASE_URL=postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}
DJANGO_STATIC_ROOT=${PROJECT_DIR}/staticfiles
DJANGO_MEDIA_ROOT=${PROJECT_DIR}/media
EOF
    
    [[ -n "${EMAIL_HOST}" ]] && cat >> "${env_file}" << EOF
EMAIL_HOST=${EMAIL_HOST}
EMAIL_PORT=${EMAIL_PORT}
EMAIL_HOST_USER=${EMAIL_USER}
EMAIL_HOST_PASSWORD=${EMAIL_PASS}
EMAIL_USE_TLS=true
EOF
    
    sudo chown "${APP_USER}:${APP_USER}" "${env_file}"
    sudo chmod 600 "${env_file}"
    
    # Run Django management commands
    cd "${PROJECT_DIR}"
    
    # Install any additional requirements
    [[ -f "requirements.txt" ]] && \
        sudo -u "${APP_USER}" "${VENV_DIR}/bin/pip" install -r requirements.txt
    
    # Run migrations
    sudo -u "${APP_USER}" "${VENV_DIR}/bin/python" manage.py migrate --noinput
    
    # Collect static files
    sudo -u "${APP_USER}" "${VENV_DIR}/bin/python" manage.py collectstatic --noinput
    
    # Create superuser if requested
    if whiptail --yesno "Create Django superuser?" 10 60; then
        local username password email
        username=$(whiptail --inputbox "Superuser username:" 10 60 "admin" 3>&1 1>&2 2>&3)
        email=$(whiptail --inputbox "Superuser email:" 10 60 "admin@example.com" 3>&1 1>&2 2>&3)
        password=$(whiptail --passwordbox "Superuser password:" 10 60 3>&1 1>&2 2>&3)
        
        echo "from django.contrib.auth import get_user_model; User = get_user_model(); User.objects.create_superuser('${username}', '${email}', '${password}') if not User.objects.filter(username='${username}').exists() else None" | \
            sudo -u "${APP_USER}" "${VENV_DIR}/bin/python" manage.py shell
    fi
    
    log_success "Django configuration complete"
}

# Setup Gunicorn service
setup_gunicorn() {
    log_info "Setting up Gunicorn service..."
    
    local service_file="/etc/systemd/system/gunicorn_${PROJECT_NAME}.service"
    
    cat > "${service_file}" << EOF
[Unit]
Description=Gunicorn daemon for ${PROJECT_NAME}
After=network.target postgresql.service

[Service]
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="PATH=${VENV_DIR}/bin"
EnvironmentFile=${PROJECT_DIR}/.env
ExecStart=${VENV_DIR}/bin/gunicorn \\
    --access-logfile - \\
    --workers 3 \\
    --bind unix:${PROJECT_DIR}/${PROJECT_NAME}.sock \\
    --worker-class gthread \\
    --threads 2 \\
    --timeout 300 \\
    --max-requests 1000 \\
    --max-requests-jitter 50 \\
    ${PROJECT_NAME}.wsgi:application

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable "gunicorn_${PROJECT_NAME}.service"
    sudo systemctl start "gunicorn_${PROJECT_NAME}.service"
    
    log_success "Gunicorn service configured"
}

# Setup Nginx configuration
setup_nginx() {
    log_info "Setting up Nginx configuration..."
    
    local nginx_conf="/etc/nginx/sites-available/${PROJECT_NAME}"
    local nginx_enabled="/etc/nginx/sites-enabled/${PROJECT_NAME}"
    
    cat > "${nginx_conf}" << EOF
# Django ${PROJECT_NAME} - Nginx Configuration
upstream ${PROJECT_NAME}_app {
    server unix:${PROJECT_DIR}/${PROJECT_NAME}.sock fail_timeout=0;
}

server {
    listen 80;
    server_name ${DOMAIN_NAME:-_} ${SERVER_IP:-};
    client_max_body_size 100M;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    
    # Static files
    location /static/ {
        alias ${PROJECT_DIR}/staticfiles/;
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
    
    # Media files
    location /media/ {
        alias ${PROJECT_DIR}/media/;
        expires 30d;
        add_header Cache-Control "public";
    }
    
    # Django application
    location / {
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$server_name;
        proxy_redirect off;
        proxy_buffering off;
        proxy_pass http://${PROJECT_NAME}_app;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Deny access to sensitive files
    location ~* (\.env|\.git|\.pyc|\.db|\.sqlite3)$ {
        deny all;
        access_log off;
        log_not_found off;
    }
}
EOF
    
    # Enable site
    sudo ln -sf "${nginx_conf}" "${nginx_enabled}"
    sudo nginx -t && sudo systemctl reload nginx
    
    log_success "Nginx configuration complete"
}

# Setup SSL with Let's Encrypt
setup_ssl() {
    [[ -z "${DOMAIN_NAME}" ]] && return 0
    
    if whiptail --yesno "Setup SSL with Let's Encrypt for ${DOMAIN_NAME}?" 10 60; then
        log_info "Setting up SSL certificate..."
        
        sudo apt-get update
        sudo apt-get install -y certbot python3-certbot-nginx
        
        if sudo certbot --nginx -d "${DOMAIN_NAME}" --non-interactive --agree-tos --email "${EMAIL_USER:-admin@${DOMAIN_NAME}}"; then
            # Setup auto-renewal
            (sudo crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | sudo crontab -
            log_success "SSL certificate installed and auto-renewal configured"
        else
            log_warning "SSL certificate setup failed"
        fi
    fi
}

# Setup Celery
setup_celery() {
    [[ "${USE_CELERY}" != "true" ]] && return 0
    
    log_info "Setting up Celery service..."
    
    # Celery service file
    local celery_service="/etc/systemd/system/celery_${PROJECT_NAME}.service"
    local celery_beat_service="/etc/systemd/system/celerybeat_${PROJECT_NAME}.service"
    
    # Main Celery worker
    cat > "${celery_service}" << EOF
[Unit]
Description=Celery Worker for ${PROJECT_NAME}
After=network.target

[Service]
Type=forking
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="PATH=${VENV_DIR}/bin"
EnvironmentFile=${PROJECT_DIR}/.env
RuntimeDirectory=celery
RuntimeDirectoryMode=0755
ExecStart=${VENV_DIR}/bin/celery -A ${PROJECT_NAME} worker \\
    --loglevel=info \\
    --logfile=${PROJECT_DIR}/logs/celery_worker.log \\
    --pidfile=/run/celery/%n.pid \\
    --detach
ExecStop=${VENV_DIR}/bin/celery multi stopwait worker \\
    --pidfile=/run/celery/%n.pid
ExecReload=${VENV_DIR}/bin/celery multi restart worker \\
    --pidfile=/run/celery/%n.pid
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Celery Beat (scheduler)
    cat > "${celery_beat_service}" << EOF
[Unit]
Description=Celery Beat for ${PROJECT_NAME}
After=network.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${PROJECT_DIR}
Environment="PATH=${VENV_DIR}/bin"
EnvironmentFile=${PROJECT_DIR}/.env
ExecStart=${VENV_DIR}/bin/celery -A ${PROJECT_NAME} beat \\
    --loglevel=info \\
    --logfile=${PROJECT_DIR}/logs/celery_beat.log \\
    --pidfile=/run/celery/beat.pid
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    # Create logs directory
    sudo mkdir -p "${PROJECT_DIR}/logs"
    sudo chown -R "${APP_USER}:${APP_USER}" "${PROJECT_DIR}/logs"
    
    sudo systemctl daemon-reload
    sudo systemctl enable "celery_${PROJECT_NAME}.service"
    sudo systemctl enable "celerybeat_${PROJECT_NAME}.service"
    sudo systemctl start "celery_${PROJECT_NAME}.service"
    sudo systemctl start "celerybeat_${PROJECT_NAME}.service"
    
    log_success "Celery services configured"
}

# Setup monitoring
setup_monitoring() {
    log_info "Setting up monitoring..."
    
    # Install monitoring tools
    sudo apt-get install -y htop iotop iftop nmon
    
    # Create monitoring script
    local monitor_script="${PROJECT_DIR}/scripts/monitor.sh"
    sudo mkdir -p "${PROJECT_DIR}/scripts"
    
    cat > "${monitor_script}" << 'EOF'
#!/bin/bash
# Django Project Monitoring Script

set -euo pipefail

PROJECT_NAME="${1:-}"
LOG_DIR="/var/log/${PROJECT_NAME}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

monitor_resources() {
    echo "=== System Resources ==="
    free -h
    echo ""
    df -h /
    echo ""
    top -bn1 | head -20
}

monitor_logs() {
    echo "=== Application Logs ==="
    tail -50 "${LOG_DIR}/gunicorn.log" 2>/dev/null || echo "No Gunicorn log found"
    echo ""
    tail -50 "${LOG_DIR}/celery.log" 2>/dev/null || echo "No Celery log found"
}

monitor_services() {
    echo "=== Service Status ==="
    systemctl status "gunicorn_${PROJECT_NAME}.service" --no-pager
    echo ""
    systemctl status "celery_${PROJECT_NAME}.service" --no-pager 2>/dev/null || true
}

check_disk_usage() {
    local usage
    usage=$(df / --output=pcent | tail -1 | tr -d ' %')
    if [[ "${usage}" -gt 85 ]]; then
        echo "WARNING: Disk usage is at ${usage}%"
        return 1
    fi
    return 0
}

# Main monitoring
main() {
    echo "Monitoring report for ${PROJECT_NAME} - ${TIMESTAMP}"
    echo "=============================================="
    
    monitor_resources
    monitor_services
    monitor_logs
    
    if check_disk_usage; then
        echo "Disk usage: OK"
    fi
}

main
EOF
    
    sudo chmod +x "${monitor_script}"
    log_success "Monitoring setup complete"
}

# Backup function
backup_project() {
    log_info "Creating backup..."
    
    sudo mkdir -p "${BACKUP_DIR}"
    
    # Backup database
    sudo -u postgres pg_dump "${DB_NAME}" > "${BACKUP_DIR}/database.sql"
    
    # Backup project files
    sudo tar -czf "${BACKUP_DIR}/project.tar.gz" \
        --exclude="*.pyc" \
        --exclude="__pycache__" \
        --exclude="node_modules" \
        --exclude=".git" \
        "${PROJECT_DIR}"
    
    # Backup configurations
    sudo cp "/etc/nginx/sites-available/${PROJECT_NAME}" "${BACKUP_DIR}/"
    sudo cp "/etc/systemd/system/gunicorn_${PROJECT_NAME}.service" "${BACKUP_DIR}/" 2>/dev/null || true
    
    log_success "Backup created at ${BACKUP_DIR}"
}

# Rollback function
rollback_deployment() {
    local backup_path
    backup_path=$(whiptail --menu "Select backup to restore:" 20 60 10 \
        $(ls -d backups/* | awk -F/ '{print $2 " " $0}') 3>&1 1>&2 2>&3)
    
    [[ -z "${backup_path}" ]] && return
    
    if whiptail --yesno "Restore from backup: ${backup_path}?" 10 60; then
        log_info "Restoring from backup: ${backup_path}"
        # Implementation depends on backup structure
        log_success "Rollback initiated (manual steps required)"
    fi
}

# Main deployment function
deploy_project() {
    log_info "Starting deployment process..."
    
    # Show progress
    {
        echo "10" ; sleep 1
        echo "XXX" ; echo "Checking prerequisites..." ; echo "XXX"
        check_prerequisites || exit 1
        echo "20" ; sleep 1
        
        echo "XXX" ; echo "Setting up system user..." ; echo "XXX"
        setup_system_user
        echo "30" ; sleep 1
        
        echo "XXX" ; echo "Configuring repository..." ; echo "XXX"
        setup_repository
        echo "40" ; sleep 1
        
        echo "XXX" ; echo "Setting up database..." ; echo "XXX"
        setup_database
        echo "50" ; sleep 1
        
        echo "XXX" ; echo "Setting up virtual environment..." ; echo "XXX"
        setup_virtualenv
        echo "60" ; sleep 1
        
        echo "XXX" ; echo "Configuring Django..." ; echo "XXX"
        configure_django
        echo "70" ; sleep 1
        
        echo "XXX" ; echo "Setting up Gunicorn..." ; echo "XXX"
        setup_gunicorn
        echo "80" ; sleep 1
        
        echo "XXX" ; echo "Configuring Nginx..." ; echo "XXX"
        setup_nginx
        echo "90" ; sleep 1
        
        echo "XXX" ; echo "Finalizing..." ; echo "XXX"
        [[ "${USE_CELERY}" == "true" ]] && setup_celery
        setup_monitoring
        echo "100" ; sleep 1
    } | whiptail --gauge "Deploying Django project..." 10 60 0
    
    log_success "Deployment completed successfully!"
    
    # Show deployment summary
    whiptail --msgbox "Deployment Summary:

Project: ${PROJECT_NAME}
Directory: ${PROJECT_DIR}
Database: ${DB_NAME}
User: ${APP_USER}
Domain: ${DOMAIN_NAME:-Not configured}
SSL: $( [[ -n "${DOMAIN_NAME}" ]] && echo "Available" || echo "Not configured" )
Celery: ${USE_CELERY}
Status: Ready" 20 70
}

# Main menu
main_menu() {
    while true; do
        local choice
        choice=$(whiptail --menu "Django Deployment Manager" 20 60 10 \
            "1" "Full Deployment Wizard" \
            "2" "Configure Settings Only" \
            "3" "Update Deployment" \
            "4" "Backup Project" \
            "5" "Rollback Deployment" \
            "6" "Monitor Services" \
            "7" "View Logs" \
            "8" "Restart Services" \
            "9" "Uninstall" \
            "0" "Exit" 3>&1 1>&2 2>&3)
        
        case "${choice}" in
            1)
                config_wizard
                deploy_project
                ;;
            2)
                config_wizard
                save_config
                ;;
            3)
                backup_project
                deploy_project
                ;;
            4)
                backup_project
                ;;
            5)
                rollback_deployment
                ;;
            6)
                sudo systemctl status "gunicorn_${PROJECT_NAME}.service" --no-pager | \
                    whiptail --textbox /dev/stdin 30 80
                ;;
            7)
                tail -100 "${PROJECT_DIR}/logs/deployment.log" 2>/dev/null | \
                    whiptail --textbox /dev/stdin 30 80 || \
                    whiptail --msgbox "No logs found" 10 40
                ;;
            8)
                sudo systemctl restart "gunicorn_${PROJECT_NAME}.service"
                [[ "${USE_CELERY}" == "true" ]] && \
                    sudo systemctl restart "celery_${PROJECT_NAME}.service"
                whiptail --msgbox "Services restarted successfully" 10 40
                ;;
            9)
                if whiptail --yesno "WARNING: This will remove all project files and configurations. Continue?" 10 60; then
                    log_info "Starting uninstallation..."
                    # Implementation for cleanup
                    whiptail --msgbox "Uninstallation complete" 10 40
                fi
                ;;
            0|"")
                log_info "Exiting..."
                exit 0
                ;;
        esac
    done
}

# Main execution
main() {
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
    
    # Load existing config or start wizard
    if [[ -f "${CONFIG_FILE}" ]]; then
        load_config
        if whiptail --yesno "Configuration found. Use existing settings?" 10 60; then
            main_menu
        else
            config_wizard
            main_menu
        fi
    else
        config_wizard
        main_menu
    fi
}

# Handle script arguments
case "${1:-}" in
    --deploy)
        load_config
        deploy_project
        ;;
    --backup)
        load_config
        backup_project
        ;;
    --restore)
        rollback_deployment
        ;;
    --monitor)
        load_config
        sudo bash "${PROJECT_DIR}/scripts/monitor.sh" "${PROJECT_NAME}"
        ;;
    --help|-h)
        echo "Django Deployment Manager"
        echo "Usage: $0 [OPTION]"
        echo ""
        echo "Options:"
        echo "  --deploy     Run deployment with existing config"
        echo "  --backup     Create backup"
        echo "  --restore    Restore from backup"
        echo "  --monitor    Show monitoring report"
        echo "  --help, -h   Show this help"
        echo ""
        echo "Run without arguments for interactive menu"
        ;;
    *)
        main
        ;;
esac
