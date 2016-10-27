#!/bin/bash
set -o errexit

if [ ! $1 ] ; then
  echo "Usage: $0 -i/-instance <instance id> -s/-size <size of new volume> -r/-region <amazon region>"
  exit 1
fi

while getopts :i:s:r: opt; do
  case $opt in
  i)
      instanceid=$OPTARG
      ;;
  s)
      size=$OPTARG
      ;;
  r)
      region=$OPTARG
      ;;
  esac
done

if [ ! $instanceid ]; then
  echo "instance id required!"
  exit 1
fi

if [ -z $size ]; then
  echo "no size entered, defaulting to 40 Gb."
  # Set a reasonable default size if unset
  size=40
fi

if [ ! $region ]; then
  echo "using default region us-east-1"
  region="us-east-1"
fi

oldvolumeid=$(ec2-describe-instances $instanceid --region=$region|egrep "^BLOCKDEVICE./dev/sda1" | cut -f3)
zone=$(ec2-describe-instances $instanceid --region=$region|grep "^INSTANCE" | cut -f12)

if [ ! $zone ]; then
  echo "can't find availability zone!"
  exit 1
fi

if [ ! $oldvolumeid ]; then
  echo "no volume detected!"
  #Allow users to enter a custom volume in case script failed after detaching
  printf "Do you want to manually enter a volume ID? [Y/n] :"
  read CUSTOMVOL
  if [[ $CUSTOMVOL == "y" ]] || [[ $CUSTOMVOL == "Y" ]]; then
    echo ""
    printf "enter volume ID :"
    read VOLUME
    oldvolumeid=$VOLUME
      if [ -z $oldvolumeid ]; then
        echo "volume null, aborting."
        exit 1
      fi
  else
    echo "OK, Aborting."
    exit 1
  fi
else
  checkvol=1
fi

set -o nounset

echo "This will stop instance $instanceid in region $region and zone $zone with original volume $oldvolumeid."
printf "Are you sure you want to proceed? [Y/n] :"
read CONFIRM
if [[ $CONFIRM == "y" ]] || [[ $CONFIRM == "Y" ]]; then
        echo "Starting resize operation now."
else
        echo "Acknowledged, Y was not chosen.  Exiting."
        exit 1
fi

echo "OK. Stopping instance $instanceid in region $region and zone $zone with original volume $oldvolumeid now."
ec2-stop-instances $instanceid --region=$region

if [[ checkvol == 1 ]]; then
    echo "detaching volume..."
    while ! ec2-detach-volume $oldvolumeid --region=$region; do sleep 5; done
fi

snapshotid=$(ec2-create-snapshot $oldvolumeid --region=$region| cut -f2)
echo "Now Running: while ec2-describe-snapshots $snapshotid | grep -q pending; do sleep 10; done"
while ec2-describe-snapshots $snapshotid --region=$region| grep -q pending; do sleep 10;echo "snapshot still pending..."; done
echo "snapshot: $snapshotid"
echo "creating new volume..."
newvolumeid=$(ec2-create-volume --region=$region --availability-zone $zone --size $size --snapshot $snapshotid | cut -f2)
echo "new volume: $newvolumeid. waiting for volume creation to finish..."

# Waiting for volume to create
sleep 15
echo "attaching new volume to $instanceid"
ec2-attach-volume --instance $instanceid --region=$region --device /dev/sda1 $newvolumeid

while ! ec2-describe-volumes $newvolumeid --region=$region | grep -q attached; do sleep 10; echo "waiting for volume to attach..."; done
echo "starting instance..."
ec2-start-instances $instanceid --region=$region
while ! ec2-describe-instances $instanceid --region=$region | grep -q running; do sleep 10; echo "waiting for instance to start..."; done
ec2-describe-instances $instanceid --region=$region
echo "deleting snapshot of resized volume"
ec2-delete-snapshot $snapshotid --region=$region
echo "When satisfied, you can run `ec2delvol $oldvolumeid --region=$region` to clean up the old volume."
printf "Would you like to clean up the old volume now? [Y/n] :"
read DELETE
if [[ $DELETE == "y" ]] || [[ $DELETE == "Y" ]]; then
        echo "Acknowledged, deleting old volume."
        ec2delvol $oldvolumeid --region=$region
else
        echo "Acknowledged, Y was not chosen. Exiting."
        exit 1
fi
