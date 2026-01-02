### Network-Latency-Equalizer
## ONLY FOR SELF-HOSTED SERVERS VIA VPS/VDS/DS

## Description
Manage your clients (users) latency and set it to your minimum. For example, you can launch script with 30 latency minimum and everyone who has less latency then 30 - will get additional latency to be with 30. If client has equal or more ping then 30 - nothing happen.

## Features
1. Add clients additional latency if client has less then setted minimum.
2. Support clients latency issues (not stable) with on-time additional latency abjustment.
3. Support multiple servers with one script.

## Installation
(You dont need "sudo" if you already admin user)
1. Put "ping.sh" and "runping" files to /opt/ping ("mkdir ping" if folder do not exist)
2. Unzip plugin "PingReporter.zip" to servers that you need (each server must have its own copy of plugin)
3. Inside plugin folder edit pingreporter.cfg
```
proxy_ip = YOUR_SERVER_IP
proxy_port = PING_PORT
```
5. Write this commands on your VPS/VDS/DS:
```shell
sudo chmod +x /opt/ping/ping.sh
sudo chmod +x /opt/ping/runping
sudo ln -s /opt/ping/runping /usr/local/bin/runping
```

## Usage
(You dont need "sudo" if you already admin user)
1. Start
```shell
sudo runping port1 ping_port1 ping1 port2 ping_port2 ping2 port3 ping_port3 ping3 ....
```
2. Restart
```shell
sudo runping -r
# OR
sudo runping —restart
```
3. Delete
```shell
sudo runping -d
# OR
sudo runping -delete
```

## MANUAL USAGE

```shell
sudo chmod +x /path/to/script/ping.sh
/path/to/script/ping.sh port1 ping_port1 ping1 port2 ping_port2 ping2 port3 ping_port3 ping3 ....
```

## EXAMPLE
1. pingreporter.cfg
```
proxy_ip = 177.177.177.177
proxy_port = 27020
```
2. Your server address: 177.177.177.177:27015
3. Launch script:
```shell
sudo runping 27015 27020 30
# 27015 - SERVER_PORT
# 27020 - PING_PORT from pingreporter.cfg
# 30 - minimum ping to set
```
