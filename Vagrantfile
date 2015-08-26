# -*- mode: ruby -*-
# vi: set ft=ruby :

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
  config.vm.define "deb" do |deb|
    deb.vm.box = "ubuntu/trusty64"
    deb.vm.provision "shell", path: "vagrant/deb.sh"
  end

  config.vm.define "rpm" do |rpm|
    rpm.vm.box = "chef/fedora-20"
    rpm.vm.provision "shell", path: "vagrant/rpm.sh"
  end

  config.vm.synced_folder "~/.gnupg", "/root/.gnupg", owner: "root", group: "root"

  config.vm.provider "virtualbox" do |vb|
    # We need 2GB+ memory because some build commands (e.g. for Kafka) run JVMs
    # with 1GB heap space each.
    vb.customize ["modifyvm", :id, "--memory", "3072"]
    vb.customize ["modifyvm", :id, "--cpus", "2"]

    ### Improve network speed for Internet access.
    # Setting 1: Use a paravirtualized network adapter (virtio-net)
    # http://superuser.com/a/850389/278185 and
    # http://auramo.github.io/2014/12/vagrant-performance-tuning/
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
    vb.customize ["modifyvm", :id, "--nictype2", "virtio"]
    # Setting 2: Use NAT'd DNS
    # http://serverfault.com/a/595010 and
    # https://github.com/mitchellh/vagrant/issues/1807
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    # Setting 3: Disable DNS proxy
    # http://serverfault.com/questions/495914#comment801426_595010
    vb.customize ["modifyvm", :id, "--natdnsproxy1", "off"]
  end
end
