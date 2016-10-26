#!/bin/bash
set -o errexit
set -o nounset

size=40

oldvolumeid=$(ec2-describe-instances $instanceid |egrep "^BLOCKDEVICE./dev/sda1" | cut -f3)
zone=$(ec2-describe-instances $instanceid |grep "^INSTANCE" | cut -f12)

echo "instance $instanceid in $zone with original volume $oldvolumeid"
ec2-stop-instances $instanceid
while ! ec2-detach-volume $oldvolumeid; do sleep 5; done

snapshotid=$(ec2-create-snapshot $oldvolumeid | cut -f2)
echo "Now Running: while ec2-describe-snapshots $snapshotid | grep -q pending; do sleep 10; done"
while ec2-describe-snapshots $snapshotid | grep -q pending; do sleep 10; done
echo "snapshot: $snapshotid"

newvolumeid=$(ec2-create-volume --availability-zone $zone --size $size --snapshot $snapshotid | cut -f2)
echo "new volume: $newvolumeid"

# Waiting for volume to create
sleep 15

ec2-attach-volume --instance $instanceid --device /dev/sda1 $newvolumeid

while ! ec2-describe-volumes $newvolumeid | grep -q attached; do sleep 10; done
ec2-start-instances $instanceid
while ! ec2-describe-instances $instanceid | grep -q running; do sleep 10; done
ec2-describe-instances $instanceid
ec2-delete-snapshot $snapshotid
echo "When satisfied, run `ec2delvol $oldvolumeid` to clean up the old volume."
