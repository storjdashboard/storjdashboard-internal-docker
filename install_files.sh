#!/bin/bash

# Define file contents
DOCKER_COMPOSE_CONTENT=$(cat <<'EOF'
version: '3.8'

services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    ports:
      - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
      - ./my_custom.cnf:/etc/mysql/my.cnf
    networks:
      - default

  apache:
    image: php:8.2-apache
    ports:
      - "${PUBLIC_PORT}:80"
    volumes:
      - ./web:/var/www/html
      - ./apache-config.conf:/etc/apache2/sites-available/000-default.conf
      - ./php.ini:/usr/local/etc/php/php.ini
    depends_on:
      - mysql
    networks:
      - default

volumes:
  mysql_data:

networks:
  default:
    driver: bridge
EOF
)

APACHE_CONFIG_CONTENT=$(cat <<'EOF'
<VirtualHost *:80>
    DocumentRoot /var/www/html/web
    <Directory /var/www/html/web>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog /var/log/apache2/error.log
    CustomLog /var/log/apache2/access.log combined
</VirtualHost>
EOF
)

SETUP_SCRIPT_CONTENT=$(cat <<'EOF'
#!/bin/bash

# Prompt for MySQL configuration
read -p "Enter MySQL root password: " MYSQL_ROOT_PASSWORD
read -p "Enter MySQL database name: " MYSQL_DATABASE
read -p "Enter MySQL user: " MYSQL_USER
read -p "Enter MySQL password: " MYSQL_PASSWORD

# Prompt for public port
read -p "Enter the public port to expose: " PUBLIC_PORT

# Set environment variables
export MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
export MYSQL_DATABASE=$MYSQL_DATABASE
export MYSQL_USER=$MYSQL_USER
export MYSQL_PASSWORD=$MYSQL_PASSWORD
export PUBLIC_PORT=$PUBLIC_PORT

# Download the latest GitHub release
LATEST_RELEASE=$(curl -s https://api.github.com/repos/storjdashboard/storjdashboard-internal/releases/latest | grep "tarball_url" | cut -d '"' -f 4)
curl -L $LATEST_RELEASE -o latest_release.tar.gz
mkdir -p web
tar -xzf latest_release.tar.gz --strip-components=1 -C web

# Configure sql.php
sed -i "s/\$hostname_sql = \"localhost\"/\$hostname_sql = \"mysql\"/" web/web/Connections/sql.php
sed -i "s/\$database_sql = \"your_db\"/\$database_sql = \"$MYSQL_DATABASE\"/" web/web/Connections/sql.php
sed -i "s/\$username_sql = \"your_user\"/\$username_sql = \"$MYSQL_USER\"/" web/web/Connections/sql.php
sed -i "s/\$password_sql = \"your_pw\"/\$password_sql = \"$MYSQL_PASSWORD\"/" web/web/Connections/sql.php

# Configure cfg.php
ROOT_DIR="web"
sed -i "s|.[FOLDER].|$ROOT_DIR|" web/web/cfg.php

# Ensure the web directory has the correct permissions
chown -R www-data:www-data web
chmod -R 755 web

# Create required directories for Apache and MySQL
mkdir -p apache-logs

# Start Docker Compose
docker-compose up -d

# Wait for MySQL to be ready
echo "Waiting for MySQL to start..."
timeout=20
start_time=$(date +%s)

while ! docker exec -i storjdashboard_mysql_1 mysql -uroot -p${MYSQL_ROOT_PASSWORD} -e "SHOW DATABASES;" > /dev/null 2>&1; do
  sleep 2
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  if [ $elapsed -ge $timeout ]; then
    echo "MySQL did not start in time."
#    exit 1
  fi
done

# Install mysqli extension in Apache container
docker exec -it storjdashboard_apache_1 bash -c "apt-get update && apt-get install -y libpng-dev libjpeg-dev libfreetype6-dev && docker-php-ext-install mysqli"

# Restart Apache to load new PHP extensions
docker exec storjdashboard_apache_1 service apache2 restart

docker start storjdashboard_apache_1
EOF
)

CLEANUP_SCRIPT_CONTENT=$(cat <<'EOF'
#!/bin/bash

# Stop Docker Compose services
docker-compose down

# Remove Docker volumes
docker volume rm $(docker volume ls -qf dangling=true)

# Optional: Remove Docker networks if they were created by this compose setup
# docker network rm $(docker network ls -q)
EOF
)

KILL_CLEAN_SCRIPT_CONTENT=$(cat <<'EOF'
#!/bin/bash

# Stop and remove Docker containers
docker stop storjdashboard_apache_1 storjdashboard_mysql_1
docker rm storjdashboard_apache_1 storjdashboard_mysql_1

# Remove Docker images
docker rmi $(docker images -q)

docker volume rm storjdashboard_mysql_data storjdashboard_apache-logs

# Remove all files except install_files.sh
find . -maxdepth 1 ! -name 'install_files.sh' -exec rm -rf {} +
EOF
)


# Define the content for php.ini
PHP_INI_CONTENT=$(cat <<'EOF'
memory_limit = 256M
upload_max_filesize = 1M
post_max_size = 1M
display_errors = Off
display_startup_errors = Off
error_reporting = 0
log_errors = On
error_log = /var/log/php_errors.log
EOF
)

# Define the content for my_custom.cnf
MYSQL_CONFIG_CONTENT=$(cat <<'EOF'
[mysqld]
bind-address = 0.0.0.0
default-authentication-plugin = mysql_native_password
EOF
)

# Write the content to php.ini
echo "$PHP_INI_CONTENT" > php.ini
echo "php.ini file has been created."

# Write the content to my_custom.cnf
echo "$MYSQL_CONFIG_CONTENT" > my_custom.cnf
echo "my_custom.cnf file has been created."

# Create or overwrite files
echo "$DOCKER_COMPOSE_CONTENT" > docker-compose.yml
echo "$APACHE_CONFIG_CONTENT" > apache-config.conf
echo "$SETUP_SCRIPT_CONTENT" > setup.sh
echo "$CLEANUP_SCRIPT_CONTENT" > cleanup.sh
echo "$KILL_CLEAN_SCRIPT_CONTENT" > kill-clean.sh

# Make scripts executable
chmod +x setup.sh cleanup.sh kill-clean.sh

# Inform the user
echo "Files have been installed or overwritten:"
echo "- docker-compose.yml"
echo "- apache-config.conf"
echo "- setup.sh"
echo "- cleanup.sh"
echo "- kill-clean.sh"

# Ask if the user wants to run setup.sh
read -p "Do you wish to run setup.sh now? (y/n): " yn
case $yn in
    [Yy]* )
        bash setup.sh
        ;;
    [Nn]* )
        echo "You can run ./setup.sh later to complete the setup."
        ;;
    * )
        echo "Please answer yes or no."
        ;;
esac
