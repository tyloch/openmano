#!/bin/bash

##
# Copyright 2015 Telef�nica Investigaci�n y Desarrollo, S.A.U.
# This file is part of openmano
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
#
# For those usages not covered by the Apache License, Version 2.0 please
# contact with: nfvlabs@tid.es
##

#Get configuration of a host for using it as a compute node

function usage(){
    echo  -e "usage: $0 user ip_name [>> host.yaml]\n  Get host parameters and generated a yaml file to be used for openvim host-add"
    exit 1
}

function get_hash_value() {   echo `eval  echo $\{\`echo $1[$2]\`\}`; }

function xmlpath_args()
{
  local expr="${1//\// }"
  local path=()
  local chunk tag data
  local exit_code=1
  local print_line=0
  local closing_tag=0

  while IFS='' read -r -d '<' chunk; do
    data=arguments=""
    IFS='>' read -r tag_arg data <<< "$chunk"
    IFS=' ' read -r tag arguments <<< "$tag_arg"
    #If last tag was single level remove it from path
    if [ $closing_tag -eq 1 ] 
    then 
      unset path[${#path[@]}-1]
      closing_tag=0
    fi
    #In case the tag is closed in the same line mark it
    [[ $arguments = ?*'/' ]] && closing_tag=1
    arguments="${arguments//\//}"
    case "$tag" in
      '?'*) ;;
      '!--'*) ;;
      ?*'/') ;;
      '/'?*) unset path[${#path[@]}-1] ;;
      ?*) path+=("$tag");;        
    esac
    
    #echo "\"${path[@]}\" \"$expr\" \"$data\" \"$arguments\" $exit_code $print_line"
    
    if [[ "${path[@]}" == "$expr" ]]
    then
      #If there is data print it and append arguments if any
      if [ "$data" != "" ] 
      then
        echo "$data $arguments"
        #return code 0 means data was found
        exit_code=0
        continue
      #if there is no data but there are arguments print arguments
      elif [ "$arguments" != "" ]
      then
        echo "$arguments"
        #return code 2 means no data but arguments were found
        exit_code=2
        continue
      #otherwise switch flag to start/stop echoing each line until the tag is closed
      elif [[ $exit_code -eq 1 ]]
      then
        print_line=$(((print_line+1)%2))
        #return code 3 means that the whole xml segment is returned
        exit_code=3
      fi
    fi
    [ $print_line == "1" ] && echo "<"$chunk
  done
  return $exit_code
}


#check root privileges and non a root user behind

[ "$#" -lt "2" ] && echo "Missing parameters" && usage
HOST_NAME=`cat /etc/hostname`
FEATURES=`grep "^flags"  /proc/cpuinfo`
FEATURES_LIST=""
if echo $FEATURES | grep -q pdpe1gb ; then FEATURES_LIST="${FEATURES_LIST},lps";  fi
if echo $FEATURES | grep -q dca     ; then FEATURES_LIST="${FEATURES_LIST},dioc"; fi
if echo $FEATURES | egrep -q "(vmx|svm)" ; then FEATURES_LIST="${FEATURES_LIST},hwsv"; fi
if echo $FEATURES | egrep -q "(ept|npt)" ; then FEATURES_LIST="${FEATURES_LIST},tlbps"; fi
if echo $FEATURES | grep -q ht      ; then FEATURES_LIST="${FEATURES_LIST},ht";   fi
if echo $FEATURES | grep -q pdpe1gb ; then FEATURES_LIST="${FEATURES_LIST},lps";  fi
if uname -m | grep -q x86_64        ; then FEATURES_LIST="${FEATURES_LIST},64b";  fi
if dmesg | grep -q -e Intel-IOMMU   ; then FEATURES_LIST="${FEATURES_LIST},iommu";  fi
FEATURES_LIST=${FEATURES_LIST#,}

NUMAS=`gawk 'BEGIN{numas=0;}
  ($1=="physical" && $2=="id" ){ if ($4+1>numas){numas=$4+1} };
  END{printf("%d",numas);}' /proc/cpuinfo`

CPUS=`gawk '($1=="processor"){pro=$3;}
  ($1=="physical" && $2=="id"){ phy=$4;}
  ($1=="core" && $2=="id"){printf " %d-%d-%d", phy,$4,pro;}' /proc/cpuinfo`

if grep -q isolcpus /proc/cmdline
then
  isolcpus=`cat /proc/cmdline`
  isolcpus=${isolcpus##*isolcpus=}
  isolcpus=${isolcpus%% *}
  isolcpus=${isolcpus//,/ }
else
  isolcpus=""
fi


#obtain interfaces information
OLDIFS=$IFS
IFS=$'\n'
unset PF_list
unset VF_list
for device in `virsh nodedev-list --cap net | grep -v net_lo_00_00_00_00_00_00`
do
virsh nodedev-dumpxml $device > device_xml
name=`xmlpath_args "device/capability/interface" < device_xml`
name="${name// /}"
address=`xmlpath_args "device/capability/address" < device_xml`
address="${address// /}"
parent=`xmlpath_args "device/parent" < device_xml`
parent="${parent// /}"
#the following line created variables 'speed' and 'state'
eval `xmlpath_args "device/capability/link" < device_xml`
virsh nodedev-dumpxml $parent > parent_xml
driver=`xmlpath_args "device/driver/name" < parent_xml`
[ $? -eq 1 ] && driver="N/A"
driver="${driver// /}"
#the following line creates a 'node' variable
eval `xmlpath_args "device/capability/numa" < parent_xml`
#the following line creates the variable 'type'
#in case the interface is a PF the value is 'virt_functions'
#in case the interface is a VF the value is 'phys_function'
type="N/A"
eval `xmlpath_args "device/capability/capability" < parent_xml`
#obtain pci
#the following line creates the variables 'domain' 'bus' 'slot' and 'function'
eval `xmlpath_args "device/capability/iommuGroup/address" < parent_xml`
pci="${domain#*x}:${bus#*x}:${slot#*x}.${function#*x}"
underscored_pci="${pci//\:/_}"
underscored_pci="pci_${underscored_pci//\./_}"

if ( [ $driver == "ixgbe" ] || [ $driver == "i40e" ] ) 
then
  underscored_pci="pf"$underscored_pci
  PF_list[${#PF_list[@]}]=$underscored_pci
  eval declare -A $underscored_pci
  eval $underscored_pci["name"]=$name
  eval $underscored_pci["numa"]=$node
  eval $underscored_pci["mac"]=$address
  eval $underscored_pci["speed"]=$speed
  eval $underscored_pci["pci"]=$pci
  #A�ado el pci de cada uno de los hijos
  SRIOV_counter=0
  for child in `xmlpath_args "device/capability/capability/address" < parent_xml`
  do 
    SRIOV_counter=$((SRIOV_counter+1))
    #the following line creates the variables 'domain' 'bus' 'slot' and 'function'
    eval $child
    eval $underscored_pci["SRIOV"$SRIOV_counter]="${domain#*x}_${bus#*x}_${slot#*x}_${function#*x}"
  done
  eval $underscored_pci["SRIOV"]=$SRIOV_counter
  
#Si se trata de un SRIOV (tiene una capability con type 'phys_function')
elif [ $type == 'phys_function' ]
then
  underscored_pci="vf"$underscored_pci
  VF_list[${#VF_list[@]}]=$underscored_pci
  eval declare -A $underscored_pci
  eval $underscored_pci["source_name"]=$name
  eval $underscored_pci["mac"]=$address
  eval $underscored_pci["pci"]=$pci
fi
rm -f device_xml parent_xml
done
IFS=$OLDIFS

echo "#This file was created by $0"
echo "#for adding this compute node to openvim"
echo "#copy this file to openvim controller and run"
echo "#openvim host-add <this>"
echo
echo "host:"
echo "  name:    $HOST_NAME"
echo "  user:    $1"
echo "  ip_name: $2"
echo "host-data:"
echo "  name:        $HOST_NAME"
echo "  user:        $1"
echo "  ip_name:     $2"
echo "  ranking:     100"
echo "  description: $HOST_NAME"
echo "  features:    $FEATURES_LIST"
echo "  numas:"

numa=0
while [ $numa -lt $NUMAS ]
do
  echo "  - numa_socket:  $numa"
#MEMORY
  if [ -f /sys/devices/system/node/node${numa}/hugepages/hugepages-1048576kB/nr_hugepages ]
  then
    echo "    hugepages: " `cat /sys/devices/system/node/node${numa}/hugepages/hugepages-1048576kB/nr_hugepages`
  else
    #TODO hugepages of 2048kB size
    echo "    hugepages:  0"
  fi
  memory=`head -n1 /sys/devices/system/node/node${numa}/meminfo  | gawk '($5=="kB"){print $4}'`
  memory=$((memory+1048576-1))   #memory must be ceiled
  memory=$((memory/1048576))   #from `kB to GB
  echo "    memory:    $memory"

#CORES
  echo "    cores:"
  FIRST="-" #first item in a list start with "-" in yaml files, then it will set to " "
  for cpu in $CPUS
  do
    PHYSICAL=`echo $cpu | cut -f 1 -d"-"`
    CORE=`echo $cpu | cut -f 2 -d"-"`
    THREAD=`echo $cpu | cut -f 3 -d"-"`
    [ $PHYSICAL != $numa ] && continue   #skip non physical
    echo "    - core_id:   $CORE"
    echo "      thread_id: $THREAD"
    #check if eligible
    cpu_isolated="no"
    for isolcpu in $isolcpus
    do
      isolcpu_start=`echo $isolcpu | cut -f 1 -d"-"`
      isolcpu_end=`echo $isolcpu | cut -f 2 -d"-"`
      if [ $THREAD -ge $isolcpu_start -a $THREAD -le $isolcpu_end ]
      then
        cpu_isolated="yes"
        break
      fi
    done
    [ $cpu_isolated == "no" ] &&   echo "      status:    noteligible"
    FIRST=" "
  done
 
  #NIC INTERFACES
  echo "    interfaces:"
  for ((i=0; i<${#PF_list[@]};i++))
  do
    underscored_pci=${PF_list[$i]}
    pname=$(get_hash_value $underscored_pci "name")
    pnuma=$(get_hash_value $underscored_pci "numa")
    [ $pnuma != $numa ] && continue 
    pmac=$(get_hash_value $underscored_pci "mac")
    ppci=$(get_hash_value $underscored_pci "pci")
    pspeed=$(get_hash_value $underscored_pci "speed")
    pSRIOV=$(get_hash_value $underscored_pci "SRIOV")
    echo "    - source_name: $pname"
    echo "      Mbps: $pspeed"
    echo "      pci: \"$ppci\""
    echo "      mac: \"$pmac\""
    echo "      sriovs:"
    for ((j=1;j<=$pSRIOV;j++))
    do
      childSRIOV="vfpci_"$(get_hash_value $underscored_pci "SRIOV"$j)
      pname=$(get_hash_value $childSRIOV "source_name")
      index=${pname##*_}
      pmac=$(get_hash_value $childSRIOV "mac")
      ppci=$(get_hash_value $childSRIOV "pci")
      vlan=$((j+99))
      echo "      - mac: \"$pmac\""
      echo "        pci: \"$ppci\""
      echo "        source_name: $index"
      echo "        vlan: $vlan"
    done
  done

  numa=$((numa+1))
done

