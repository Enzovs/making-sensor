#NAME_PRG=citysdk_daemon
MY_SRV=airqserver
MY_TMP=/tmp/${MY_SRV}


MY_BUNDLE=$(which bundle | sed  's/\(.*\)\/bin\/\(.*\)/\1\/wrappers\/\2/g')
ORIG_DIR=$(find ${HOME}/src -type d -name ${MY_SRV})
MY_USER=$(cat ${ORIG_DIR}/Passengerfile.json | /bin/grep user | cut -d'"' -f4)
MY_CMD="${MY_BUNDLE}"

DEST_FILE=/etc/init.d/${MY_SRV}

LOG_FILE=$(cat ${ORIG_DIR}/Passengerfile.json | /bin/grep log_file | cut -d'"' -f4)
LOG_DIR=$(dirname ${LOG_FILE})

cd ${ORIG_DIR}

FILT_DIR=$(echo ${ORIG_DIR} | sed 's/\//\\\//g')
FILT_CMD=$(echo ${MY_CMD} | sed 's/\//\\\//g')

bundle install
#MY_GEMS="$(gem env gempath)"
#MY_GEMS="$(bundle env | /bin/grep GEM_PATH | sed 's/GEM_PATH \(.*\)/\1/g' | cut -f1 -d':')"
MY_GEMS="$(for i in $(gem env gempath | tr ':' '\n'); do echo ${i}/wrappers;done | tr '\n' ':')"
FILT_GEMS=$(echo ${MY_GEMS} | sed 's/\//\\\//g')

#cat airqserver.service | sed "s/^BASE_DIR=$/BASE_DIR=${FILT_DIR}/g" | sed "s/^MY_CMD=$/MY_CMD=\"${FILT_CMD}\"/g" > ${MY_TMP}
cat ${MY_SRV}.service | sed "s/^BASE_DIR=$/BASE_DIR=${FILT_DIR}/g" | sed "s/^export PATH=$/export PATH=\${PATH}:${FILT_GEMS}/g" > ${MY_TMP}

sudo mv ${MY_TMP} ${DEST_FILE}

sudo chown root:root ${DEST_FILE}

sudo chmod u+x ${DEST_FILE}

sudo update-rc.d ${MY_SRV} defaults 98 02

if [ ! -d "${LOG_DIR}" ]
then
  sudo mkdir -p ${LOG_DIR}
fi

sudo chown -R ${MY_USER}:${MY_USER} ${LOG_DIR}

FILT_LOGFILE=$(echo ${LOG_FILE} | sed 's/\//\\\//g')

cat ${MY_SRV}.logrotate | sed "s/^LOG_FILE {/${FILT_LOGFILE} {/g" | sed "s/\(.*\)SERVICE\(.*\)/\1${MY_SRV}\2/g" > ${MY_TMP}

sudo mv ${MY_TMP} /etc/logrotate.d/${MY_SRV}

sudo chown root:root /etc/logrotate.d/${MY_SRV}

sudo chmod 644 /etc/logrotate.d/${MY_SRV}

sudo service ${MY_SRV} restart


#NAMEPID=$(ps -ef | /bin/grep -i "screen -S ${NAME_PRG}" | /bin/grep -v 'grep -i')

#if [ "${NAMEPID} " != " " ]
#then
#  screen -S ${NAME_PRG}.${NAMEPID} -X quit
#fi

#bundle install
#rvmsudo bundle exec passenger start

#screen -S ${NAME_PRG} -d -m bundle exec passenger start
