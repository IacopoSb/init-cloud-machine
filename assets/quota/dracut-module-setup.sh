#!/bin/bash
# dracut module 99ext4quota: abilita la project quota sul filesystem di root
# (ext4) al boot, mentre è ancora smontato — la feature quota non si può
# abilitare a caldo. Include tune2fs/blkid e un hook pre-mount.
# Parte di init-cloud-machine (installato da init.sh su Ubuntu con dracut).
check() { return 0; }
depends() { echo ""; }
install() {
    inst_multiple tune2fs blkid
    inst_hook pre-mount 50 "$moddir/ext4-quota.sh"
}
