#!/bin/bash

# 1. Cek apakah Nginx sudah terinstal
if ! command -v nginx &> /dev/null
then
    echo "Nginx tidak ditemukan, menginstal Nginx..."
    # Install Nginx jika belum ada
    sudo apt update > /dev/null 2>&1
    sudo apt install -y nginx > /dev/null 2>&1
else
    echo "Nginx sudah terinstal."
fi

# 2. Membuat file konfigurasi untuk Nginx
echo "Membuat konfigurasi Nginx untuk aplikasi..."

cat <<EOL | sudo tee /etc/nginx/sites-available/acsui > /dev/null
server {
    listen 80;
    server_name localhost; # Ganti dengan IP VPS Anda

    root /var/www/acsui;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    # Proxy untuk /acs/devices dan menghapus /acs dari URL
    location /acs/ {
        # Menggunakan rewrite untuk menghapus '/acs' dari path
        rewrite ^/acs(/.*)$ \$1 break;  # Menghapus '/acs' dari path yang diteruskan
        proxy_pass http://localhost:7557;  # Ganti dengan alamat server Anda
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Proxy untuk /login
    location /login {
        proxy_pass http://localhost:3000;  # Ganti dengan alamat server login Anda
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Enable gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
}
EOL

# 3. Membuat symbolic link ke sites-enabled
echo "Membuat symbolic link untuk Nginx..."
sudo ln -s /etc/nginx/sites-available/acsui /etc/nginx/sites-enabled/ > /dev/null 2>&1

# 4. Memastikan Nginx berjalan dengan baik
echo "Memeriksa konfigurasi Nginx..."
sudo nginx -t > /dev/null 2>&1

# Restart Nginx untuk menerapkan konfigurasi baru
echo "Restarting Nginx..."
sudo systemctl restart nginx > /dev/null 2>&1

# 5. Install Node.js dan NPM (Updated to Node.js 18 LTS)
echo "Memeriksa Node.js dan NPM..."
if ! command -v node &> /dev/null
then
    echo "Node.js tidak ditemukan, menginstal Node.js 18 LTS..."
    # Remove old Node.js repository if exists
    sudo rm -f /etc/apt/sources.list.d/nodesource.list > /dev/null 2>&1
    # Install Node.js 18 LTS dari repositori resmi
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null 2>&1
    sudo apt install -y nodejs > /dev/null 2>&1
else
    # Check Node.js version
    NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
    if [ "$NODE_VERSION" -lt 16 ]; then
        echo "Node.js versi lama terdeteksi ($NODE_VERSION), mengupgrade ke Node.js 18 LTS..."
        # Remove old Node.js repository if exists
        sudo rm -f /etc/apt/sources.list.d/nodesource.list > /dev/null 2>&1
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - > /dev/null 2>&1
        sudo apt install -y nodejs > /dev/null 2>&1
    else
        echo "Node.js sudah terinstal dengan versi yang kompatibel."
    fi
fi

# 6. Install PM2 jika belum terinstal
echo "Memeriksa apakah PM2 terinstal..."
if ! command -v pm2 &> /dev/null
then
    echo "PM2 tidak ditemukan, menginstal PM2..."
    sudo npm install -g pm2 > /dev/null 2>&1
else
    echo "PM2 sudah terinstal."
fi

# 7. Membuat file server.js untuk aplikasi Express
echo "Membuat file server.js untuk aplikasi Express..."

sudo mkdir -p /var/www/acsui > /dev/null 2>&1

echo "Extracting file.tar to /var/www/acsui..."
sudo tar -xvf file.tar -C /var/www/acsui > /dev/null 2>&1

cat <<'EOL' | sudo tee /var/www/acsui/server.js > /dev/null
const express = require('express');
const os = require('os');
const si = require('systeminformation');
const crypto = require('crypto');
const { exec } = require('child_process');
const cors = require('cors');  // Import CORS middleware

const app = express();
const port = 7000;

// Gunakan CORS untuk mengizinkan semua origin
app.use(cors());  // Ini akan mengizinkan semua origin

// Fungsi untuk mendapatkan informasi CPU
const getCpuInfo = async () => {
  if (process.platform === 'win32') {
    return new Promise((resolve, reject) => {
      exec('wmic cpu get ProcessorId', (error, stdout, stderr) => {
        if (error || stderr) {
          reject('Error fetching CPU info');
        } else {
          resolve(stdout.split('\n')[1]?.trim() || 'unknown-cpu');
        }
      });
    });
  } else {
    try {
      const cpuInfo = await si.cpu();
      return cpuInfo?.manufacturer + '-' + cpuInfo?.brand;
    } catch (error) {
      return 'unknown-cpu';
    }
  }
};

// Fungsi untuk mendapatkan machine ID dari VPS X
const getHostMachineId = async () => {
  try {
    const hostName = os.hostname();
    const cpuId = await getCpuInfo();
    const diskInfo = await si.diskLayout();
    const diskSerial = diskInfo[0]?.serialNum || 'unknown-disk';
    const macAddress = Object.values(os.networkInterfaces())
      .flat()
      .find(nic => nic && !nic.internal && nic.mac)?.mac || 'unknown-mac';

    // Debugging: Cek nilai yang dikumpulkan untuk rawId
    console.log('HostName:', hostName);
    console.log('CPU ID:', cpuId);
    console.log('Disk Serial:', diskSerial);
    console.log('MAC Address:', macAddress);

    // Gabungkan semua informasi untuk membuat rawId
    const rawId = `${hostName}-${cpuId}-${diskSerial}-${macAddress}`;

    // Debugging: Cek rawId yang dibentuk
    console.log('Raw ID:', rawId);  // Debugging

    const machineId = crypto.createHash('sha256').update(rawId).digest('hex');
    return machineId;
  } catch (error) {
    console.error('Error generating machine ID:', error);
    return 'unknown-machine-id';
  }
};

// API Endpoint untuk mendapatkan machine ID dari VPS X
app.get('/api/license/get-machine-id', async (req, res) => {
  try {
    const machineId = await getHostMachineId();
    console.log('Generated machine ID:', machineId);
    res.json({ success: true, machineId });
  } catch (error) {
    console.error('Error getting machine ID:', error);
    res.status(500).json({ success: false, error: 'Failed to generate machine ID' });
  }
});

// Menjalankan server
app.listen(port, () => {
  console.log(`Server is running on http://localhost:${port}`);
});
EOL

# 8. Menyusun aplikasi dengan PM2
echo "Menjalankan aplikasi Express menggunakan PM2..."

# Menginstal dependensi untuk Express
cd /var/www/acsui > /dev/null 2>&1

sudo npm init -y > /dev/null 2>&1

# Install dependencies with specific versions for compatibility
echo "Installing Express dependencies..."
sudo npm install express@4.18.2 systeminformation@5.17.12 cors@2.8.5 > /dev/null 2>&1

# Menghentikan dan menghapus semua aplikasi PM2 yang ada
pm2 stop all > /dev/null 2>&1
pm2 delete all > /dev/null 2>&1

# Menjalankan aplikasi menggunakan PM2 dengan opsi force (-f)
pm2 start /var/www/acsui/server.js --name "acsui" --watch -f > /dev/null 2>&1

# Menyimpan aplikasi untuk di-start otomatis saat reboot
pm2 startup > /dev/null 2>&1
pm2 save > /dev/null 2>&1

# 9. Menyelesaikan setup
echo "Setup selesai! Aplikasi Express Anda sekarang berjalan dengan Nginx di VPS X."
echo "Akses aplikasi melalui IP VPS Anda atau nama domain yang ditetapkan."
echo "Node.js version: $(node -v)"
echo "NPM version: $(npm -v)"
