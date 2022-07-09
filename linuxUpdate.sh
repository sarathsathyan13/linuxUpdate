# !/bin/bash

ping 8.8.8.8 -c 3
echo "network connected"
echo "#################################################################"
sleep 3
clear

sudo apt-get update -y
echo "update complete"
echo "#################################################################"
sleep 3
clear

sudo apt-get upgrade -y
echo "upgrade complete"
echo "#################################################################"
sleep 3
clear

sudo apt-get full-upgrade -y
echo "full upgrade complete"
echo "#################################################################"
sleep 3
clear

sudo apt-get dist-upgrade -y
echo "dist upgrade complete"
echo "#################################################################"
sleep 3
clear
