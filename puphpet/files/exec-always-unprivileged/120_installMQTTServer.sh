echo "Installing MQTT server in $(pwd)"

export DEBIAN_FRONTEND=noninteractive

#lsb_release -a

sudo service mosquitto stop

#sudo apt-get install -y uuid-dev
#sudo apt-get install -y libc-ares-dev
#sudo apt-get install -y g++

cd

if [ ! -d mosquitto-1.4.8 ]
then
  if [ ! -f mosquitto-1.4.8.tar.gz ]
  then
    wget --quiet --tries=5 --connect-timeout=10 http://mosquitto.org/files/source/mosquitto-1.4.8.tar.gz
  fi
  tar zxvf mosquitto-1.4.8.tar.gz

  cd mosquitto-1.4.8/

  # Manually:
  # vi config.mk
  #	change prefix line to prefix=/usr

  #Create temporary file with new line in place
  cat config.mk | sed -e "s/^prefix=.*/prefix=\/usr/" > config.mk.mod
  #Copy the new file over the original file
  mv config.mk.mod config.mk

  #make && make test && sudo make install
  make && sudo make install

  # update linker
  sudo ldconfig

else
  echo "mosquitto directory already exists"
fi

cd ${HOME}

if ! getent group mosquitto  >/dev/null 2>&1
then
  sudo addgroup mosquitto
fi

if ! id -u mosquitto >/dev/null 2>&1
then
  # Create user mosquitto
  sudo useradd -r -M -s /sbin/nologin -g mosquitto mosquitto
else
  sudo usermod -g mosquitto mosquitto
fi

if [ ! -d /var/log/mosquitto ]
then
  sudo mkdir /var/log/mosquitto
fi

sudo chown -R mosquitto:mosquitto /var/log/mosquitto

if [ ! -d /var/lib/mosquitto/ ]
then
  sudo mkdir /var/lib/mosquitto/
fi

sudo chown -R mosquitto:mosquitto /var/lib/mosquitto/

CONF_DIR=$(dirname $(find ${HOME}/src -type f -name mosquitto.conf))

cd ${CONF_DIR}

sudo cp mosquitto.conf pwfile aclfile /etc/mosquitto

sudo chown -R mosquitto:mosquitto /etc/mosquitto

TMP_FILE=/tmp/mosquitto

cat > ${TMP_FILE} <<End-of-message
/var/log/mosquitto/*.log {
  rotate 14
	daily
	compress
	size 1
	copytruncate
	missingok
}
End-of-message
#	postrotate
#		/usr/bin/killall -HUP mosquitto
#	endscript

sudo mv ${TMP_FILE} /etc/logrotate.d/mosquitto

sudo chown -R root:root /etc/logrotate.d/mosquitto

sudo chmod 644 /etc/logrotate.d/mosquitto

sudo service mosquitto start
