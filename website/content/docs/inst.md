########################################

## ssh into the booted nixos installer vm

## don't forget to enable ssh in the vm using `passwd`

########################################

ssh -oUserKnownHostsFile=/dev/null -oStrictHostKeyChecking=no nixos@localhost -p 10022
