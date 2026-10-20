#!/bin/sh
# Sobe o swtpm e o QEMU sobre o diretório /vm (disco, NVRAM, estado do TPM).
# Argumentos extras vão para o QEMU (o boot do instalador usa -kernel e -append).
set -eu
mkdir -p /vm/tpm
swtpm socket --tpm2 --tpmstate dir=/vm/tpm --ctrl type=unixio,path=/vm/tpm/sock \
    --log file=/vm/tpm/log --daemon
exec qemu-system-x86_64 \
    -enable-kvm -machine q35,smm=on -cpu host -m 2048 -smp 2 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
    -drive if=pflash,format=raw,unit=1,file=/vm/vars.fd \
    -drive file=/vm/disco.qcow2,if=virtio,format=qcow2 \
    -chardev socket,id=chrtpm,path=/vm/tpm/sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
    -device i6300esb \
    -display none \
    -monitor unix:/vm/monitor.sock,server=on,wait=off \
    "$@"
