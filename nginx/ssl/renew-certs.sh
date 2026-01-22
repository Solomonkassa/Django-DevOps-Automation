#!/bin/bash
# nginx/ssl/renew-certs.sh
# Automatically renew Let's Encrypt certificates

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOG_FILE="/var/log/ssl-renewal.log"
DOMAINS_FILE="/etc/nginx/ssl/domains.conf"

echo "🔄 Starting SSL certificate renewal..." | tee -a "$LOG_FILE"
echo "Date: $(date)" | tee -a "$LOG_FILE"

# Load domains from config file
if [[ ! -f "$DOMAINS_FILE" ]]; then
    echo -e "${RED}❌ Domains configuration file not found: $DOMAINS_FILE${NC}" | tee -a "$LOG_FILE"
    exit 1
fi

source "$DOMAINS_FILE"

renew_domain() {
    local domain="$1"
    local email="$2"
    local webroot="$3"
    
    echo -e "\n${YELLOW}Processing domain: $domain${NC}" | tee -a "$LOG_FILE"
    
    # Check if certificate exists and needs renewal
    if sudo certbot certificates --domain "$domain" | grep -q "VALID"; then
        echo "Certificate for $domain is valid, checking expiration..." | tee -a "$LOG_FILE"
        
        # Get expiration date
        local expiry_date
        expiry_date=$(sudo certbot certificates --domain "$domain" | grep "Expiry" | awk '{print $3}')
        
        if [[ -n "$expiry_date" ]]; then
            local days_until_expiry
            days_until_expiry=$(( ( $(date -d "$expiry_date" +%s) - $(date +%s) ) / 86400 ))
            
            if [[ $days_until_expiry -le 30 ]]; then
                echo "Certificate expires in $days_until_expiry days, renewing..." | tee -a "$LOG_FILE"
                
                # Renew certificate
                if sudo certbot renew --cert-name "$domain" --quiet; then
                    echo -e "${GREEN}✅ Successfully renewed certificate for $domain${NC}" | tee -a "$LOG_FILE"
                    
                    # Reload Nginx
                    if sudo nginx -t; then
                        sudo systemctl reload nginx
                        echo "Nginx reloaded successfully" | tee -a "$LOG_FILE"
                    else
                        echo -e "${RED}❌ Nginx configuration test failed${NC}" | tee -a "$LOG_FILE"
                        return 1
                    fi
                else
                    echo -e "${RED}❌ Failed to renew certificate for $domain${NC}" | tee -a "$LOG_FILE"
                    return 1
                fi
            else
                echo "Certificate valid for $days_until_expiry more days, skipping renewal" | tee -a "$LOG_FILE"
            fi
        fi
    else
        echo -e "${YELLOW}⚠️  No valid certificate found for $domain, attempting to obtain one...${NC}" | tee -a "$LOG_FILE"
        
        # Obtain new certificate
        if sudo certbot certonly --webroot -w "$webroot" \
            -d "$domain" \
            --email "$email" \
            --agree-tos \
            --non-interactive \
            --force-renewal; then
            echo -e "${GREEN}✅ Successfully obtained certificate for $domain${NC}" | tee -a "$LOG_FILE"
        else
            echo -e "${RED}❌ Failed to obtain certificate for $domain${NC}" | tee -a "$LOG_FILE"
            return 1
        fi
    fi
    
    return 0
}

# Process all domains
ERRORS=0
while IFS=',' read -r domain email webroot; do
    # Skip comments and empty lines
    [[ "$domain" =~ ^#.*$ ]] && continue
    [[ -z "$domain" ]] && continue
    
    renew_domain "$domain" "$email" "$webroot" || ((ERRORS++))
    
    # Sleep to avoid rate limiting
    sleep 10
done < "$DOMAINS_FILE"

# Send notification if errors occurred
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}❌ $ERRORS error(s) occurred during certificate renewal${NC}" | tee -a "$LOG_FILE"
    
    # Send email notification (requires mailx or similar)
    if command -v mailx &> /dev/null; then
        echo "SSL certificate renewal encountered $ERRORS error(s). Check $LOG_FILE for details." | \
            mailx -s "SSL Renewal Failed - $(date)" "$ADMIN_EMAIL"
    fi
    
    exit 1
else
    echo -e "${GREEN}✅ All certificates processed successfully${NC}" | tee -a "$LOG_FILE"
fi

# Cleanup old logs
find /var/log/ssl-renewal* -type f -mtime +30 -delete

echo "Renewal completed at: $(date)" | tee -a "$LOG_FILE"
