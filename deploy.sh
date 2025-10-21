#!/bin/bash

#############################################
# Production-Grade Dockerized App Deployment
# Author: HNG DevOps Intern
# Description: Automates deployment to remote server
#############################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Trap errors
trap 'error_exit "Script failed at line $LINENO"' ERR

#############################################
# HELPER FUNCTIONS
#############################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR $(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING $(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log_error "$1"
    exit 1
}

# Validate URL
validate_url() {
    local url=$1
    if [[ ! "$url" =~ ^https?:// ]]; then
        return 1
    fi
    return 0
}

# Validate IP address
validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# Validate port number
validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi
    return 1
}

#############################################
# STEP 1: COLLECT AND VALIDATE PARAMETERS
#############################################

collect_parameters() {
    log "=== Step 1: Collecting Deployment Parameters ==="
    
    # Git Repository URL
    read -p "Enter Git Repository URL (https://github.com/user/repo.git): " GIT_REPO_URL
    while ! validate_url "$GIT_REPO_URL"; do
        log_error "Invalid URL format"
        read -p "Enter Git Repository URL: " GIT_REPO_URL
    done
    
    # Personal Access Token
    read -sp "Enter Personal Access Token (PAT): " GIT_PAT
    echo
    if [ -z "$GIT_PAT" ]; then
        error_exit "PAT cannot be empty"
    fi
    
    # Branch name
    read -p "Enter branch name [main]: " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    
    # Remote server username
    read -p "Enter remote server username [ubuntu]: " SSH_USER
    SSH_USER=${SSH_USER:-ubuntu}
    
    # Remote server IP
    read -p "Enter remote server IP address: " SERVER_IP
    while ! validate_ip "$SERVER_IP"; do
        log_error "Invalid IP address"
        read -p "Enter remote server IP address: " SERVER_IP
    done
    
    # SSH key path
    read -p "Enter SSH key path [~/.ssh/id_ed25519]: " SSH_KEY_PATH
    SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_ed25519}
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    
    if [ ! -f "$SSH_KEY_PATH" ]; then
        error_exit "SSH key not found at $SSH_KEY_PATH"
    fi
    
    # Application port
    read -p "Enter application internal port [80]: " APP_PORT
    APP_PORT=${APP_PORT:-80}
    while ! validate_port "$APP_PORT"; do
        log_error "Invalid port number"
        read -p "Enter application port: " APP_PORT
    done
    
    # Container port
    read -p "Enter container external port [8080]: " CONTAINER_PORT
    CONTAINER_PORT=${CONTAINER_PORT:-8080}
    
    log "Parameters collected successfully"
}

#############################################
# STEP 2: CLONE OR UPDATE REPOSITORY
#############################################

clone_repository() {
    log "=== Step 2: Cloning/Updating Repository ==="
    
    # Extract repo name
    REPO_NAME=$(basename "$GIT_REPO_URL" .git)
    CLONE_DIR="/tmp/$REPO_NAME"
    
    # Construct authenticated URL
    AUTH_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://${GIT_PAT}@|")
    
    if [ -d "$CLONE_DIR" ]; then
        log "Repository exists. Pulling latest changes..."
        cd "$CLONE_DIR"
        git pull "$AUTH_URL" "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || error_exit "Failed to pull repository"
    else
        log "Cloning repository..."
        git clone "$AUTH_URL" "$CLONE_DIR" >> "$LOG_FILE" 2>&1 || error_exit "Failed to clone repository"
        cd "$CLONE_DIR"
        git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || error_exit "Failed to checkout branch $GIT_BRANCH"
    fi
    
    log "Repository ready at $CLONE_DIR"
}

#############################################
# STEP 3: VERIFY DOCKER FILES
#############################################

verify_docker_files() {
    log "=== Step 3: Verifying Docker Files ==="
    
    if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
        error_exit "No Dockerfile or docker-compose.yml found in repository"
    fi
    
    if [ -f "Dockerfile" ]; then
        log "Found Dockerfile"
    fi
    
    if [ -f "docker-compose.yml" ]; then
        log "Found docker-compose.yml"
    fi
}

#############################################
# STEP 4: TEST SSH CONNECTION
#############################################

test_ssh_connection() {
    log "=== Step 4: Testing SSH Connection ==="
    
    if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "echo 'SSH OK'" >> "$LOG_FILE" 2>&1; then
        log "SSH connection successful"
    else
        error_exit "Cannot connect to $SSH_USER@$SERVER_IP"
    fi
}

#############################################
# STEP 5: PREPARE REMOTE ENVIRONMENT
#############################################

prepare_remote_environment() {
    log "=== Step 5: Preparing Remote Environment ==="
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << 'ENDSSH'
        set -e
        
        echo "Updating system packages..."
        sudo apt-get update -qq
        
        echo "Installing Docker..."
        if ! command -v docker &> /dev/null; then
            sudo apt-get install -y docker.io
            sudo systemctl enable docker
            sudo systemctl start docker
        fi
        
        echo "Installing Docker Compose..."
        if ! command -v docker-compose &> /dev/null; then
            sudo apt-get install -y docker-compose
        fi
        
        echo "Installing Nginx..."
        if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
        fi
        
        echo "Adding user to docker group..."
        sudo usermod -aG docker $USER || true
        
        echo "Verifying installations..."
        docker --version
        docker-compose --version
        nginx -v 2>&1
        
        echo "Remote environment ready"
ENDSSH
    
    log "Remote environment prepared successfully"
}

#############################################
# STEP 6: DEPLOY APPLICATION
#############################################

deploy_application() {
    log "=== Step 6: Deploying Application ==="
    
    # Create remote directory
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "mkdir -p /home/$SSH_USER/app"
    
    # Transfer files
    log "Transferring files to remote server..."
    rsync -avz --exclude '.git' --exclude '.gitignore' \
        -e "ssh -i $SSH_KEY_PATH" \
        "$CLONE_DIR/" "$SSH_USER@$SERVER_IP:/home/$SSH_USER/app/" >> "$LOG_FILE" 2>&1 || error_exit "File transfer failed"
    
    # Build and run Docker container
    log "Building and running Docker container..."
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << ENDSSH
        set -e
        cd /home/$SSH_USER/app
        
        # Stop and remove old container
        sudo docker stop hng-app-container 2>/dev/null || true
        sudo docker rm hng-app-container 2>/dev/null || true
        
        # Build new image
        sudo docker build -t hng-app:latest .
        
        # Run container
        sudo docker run -d \
            --name hng-app-container \
            --restart unless-stopped \
            -p $CONTAINER_PORT:$APP_PORT \
            hng-app:latest
        
        echo "Container started successfully"
ENDSSH
    
    log "Application deployed successfully"
}

#############################################
# STEP 7: CONFIGURE NGINX REVERSE PROXY
#############################################

configure_nginx() {
    log "=== Step 7: Configuring Nginx Reverse Proxy ==="
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << ENDSSH
        set -e
        
        # Create Nginx config
        sudo tee /etc/nginx/sites-available/hng-app > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:$CONTAINER_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        
        # Remove default config
        sudo rm -f /etc/nginx/sites-enabled/default
        
        # Enable site
        sudo ln -sf /etc/nginx/sites-available/hng-app /etc/nginx/sites-enabled/
        
        # Test config
        sudo nginx -t
        
        # Reload Nginx
        sudo systemctl reload nginx
        
        echo "Nginx configured successfully"
ENDSSH
    
    log "Nginx reverse proxy configured"
}

#############################################
# STEP 8: VALIDATE DEPLOYMENT
#############################################

validate_deployment() {
    log "=== Step 8: Validating Deployment ==="
    
    # Check Docker service
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo systemctl is-active docker" >> "$LOG_FILE" 2>&1 || error_exit "Docker service not running"
    
    # Check container
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo docker ps --filter name=hng-app-container --format '{{.Status}}'" >> "$LOG_FILE" 2>&1
    
    # Check Nginx
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" "sudo systemctl is-active nginx" >> "$LOG_FILE" 2>&1 || error_exit "Nginx service not running"
    
    # Test endpoint
    log "Testing endpoint at http://$SERVER_IP..."
    sleep 3
    if curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP" | grep -q "200"; then
        log "${GREEN}✓${NC} Deployment validated successfully!"
        log "Your app is live at: ${BLUE}http://$SERVER_IP${NC}"
    else
        log_warning "Endpoint test returned non-200 status. Check manually."
    fi
}

#############################################
# CLEANUP FUNCTION
#############################################

cleanup_deployment() {
    log "=== Cleanup Mode ==="
    
    read -p "Are you sure you want to remove all deployed resources? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        log "Cleanup cancelled"
        exit 0
    fi
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SERVER_IP" bash << 'ENDSSH'
        set -e
        
        echo "Stopping and removing container..."
        sudo docker stop hng-app-container 2>/dev/null || true
        sudo docker rm hng-app-container 2>/dev/null || true
        sudo docker rmi hng-app:latest 2>/dev/null || true
        
        echo "Removing Nginx config..."
        sudo rm -f /etc/nginx/sites-available/hng-app
        sudo rm -f /etc/nginx/sites-enabled/hng-app
        sudo systemctl reload nginx
        
        echo "Removing app directory..."
        rm -rf ~/app
        
        echo "Cleanup complete"
ENDSSH
    
    log "All resources removed successfully"
}

#############################################
# MAIN EXECUTION
#############################################

main() {
    log "======================================"
    log "  Docker Deployment Automation Tool   "
    log "======================================"
    
    # Check for cleanup flag
    if [ "${1:-}" = "--cleanup" ]; then
        collect_parameters
        cleanup_deployment
        exit 0
    fi
    
    collect_parameters
    clone_repository
    verify_docker_files
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    
    log "======================================"
    log "${GREEN}✓ Deployment completed successfully!${NC}"
    log "======================================"
    log "Server IP: http://$SERVER_IP"
    log "Log file: $LOG_FILE"
}

# Run main function
main "$@"
