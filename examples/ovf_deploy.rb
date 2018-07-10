#!/usr/bin/env ruby

# Copyright (c) 2012-2017 VMware, Inc.  All Rights Reserved.
# SPDX-License-Identifier: MIT

require 'trollop'
require 'rbvmomi'
require 'rbvmomi/trollop'
require 'rbvmomi/utils/deploy'
require 'yaml'

VIM = RbVmomi::VIM

opts = Trollop.options do
  banner <<-EOS
Deploy an OVF to a cluster, using a cached template if available.

Usage:
    cached_ovf_deploy.rb [options] <vmname> <ovfurl>

VIM connection options:
    EOS

    rbvmomi_connection_opts

    text <<-EOS

VM location options:
    EOS

    rbvmomi_datacenter_opt
    rbvmomi_datastore_opt

    text <<-EOS

Other options:
  EOS

  opt :computer_path, "Path to the cluster to deploy into", :type => :string
  opt :network, "Name of the network to attach template to", :type => :strings
  opt :vm_folder_path, "Path to VM folder to deploy VM into", :type => :string
end

Trollop.die("must specify host") unless opts[:host]
Trollop.die("no cluster path given") unless opts[:computer_path]

vm_name = ARGV[0] or Trollop.die("No VM name given")
ovf_url = ARGV[1] or Trollop.die("No OVF URL given")

vim = VIM.connect opts
dc = vim.serviceInstance.find_datacenter(opts[:datacenter]) or abort "datacenter not found"
datastore = dc.find_datastore(opts[:datastore]) or abort "datastore not found"
computer = dc.find_compute_resource(opts[:computer_path]) or abort "compute not found"

root_vm_folder = dc.vmFolder
vm_folder = root_vm_folder
if opts[:vm_folder_path]
  vm_folder = root_vm_folder.traverse(opts[:vm_folder_path], VIM::Folder)
end

ovf = open(ovf_url, 'r'){|io| Nokogiri::XML(io.read)}
ovf.remove_namespaces!
networks = ovf.xpath('//NetworkSection/Network').map{|x| x['name']}
network_mappings = {}
network_list = []
# If list of networks were passed as input then map them to the VM Networks in the
# OVF.  If fewer networks are passed in that what are available on the OVF the last
# input network will be repeated on all available VMNetworks
if opts[:network]
  this_net = nil	
  opts[:network].size <= networks.size or abort "network input list to big for available networks"
  opts[:network].each_with_index do |net,index|
    this_net = computer.network.find{|x| x.name == net}
    network_mappings[networks[index]] = this_net
  end
  # If input network list was smaller than number of VM Networks in the OVF
  # Fill in remaining OVF networks with last available input network
  if opts[:network].size < networks.size
    networks[opts[:network].size..-1].each do |net|
      network_mappings[net] = this_net
    end
  end
else  
  # If no networks is passed in as input, map all networks to the first available
  # network on the host 	
  network = computer.network[0]
  network_mappings = Hash[networks.map{|x| [x, network]}]
end  
pc = vim.serviceContent.propertyCollector
hosts = computer.host
hosts_props = pc.collectMultiple(
  hosts, 
  'datastore', 'runtime.connectionState', 
  'runtime.inMaintenanceMode', 'name'
)
host = hosts.shuffle.find do |x|
  host_props = hosts_props[x] 
  is_connected = host_props['runtime.connectionState'] == 'connected'
  is_ds_accessible = host_props['datastore'].member?(datastore)
  is_connected && is_ds_accessible && !host_props['runtime.inMaintenanceMode']
end

if !host
  fail "No host in the cluster available to upload OVF to"
end

rp = computer.resourcePool
property_mappings = {}
vm = nil
begin 
  vm = vim.serviceContent.ovfManager.deployOVF(
    uri: ovf_url,
    vmName: vm_name,
    vmFolder: vm_folder,
    host: host,
    resourcePool: rp,
    datastore: datastore,
    networkMappings: network_mappings,
    propertyMappings: property_mappings)
rescue RbVmomi::Fault => fault
end

puts "#{Time.now}: Powering On VM ..."

vm.PowerOnVM_Task.wait_for_completion

puts "#{Time.now}: Waiting for VM to be up ..."
ip = nil
while !(ip = vm.guest_ip)
  sleep 5
end

puts "#{Time.now}: VM got IP: #{ip}"

puts "#{Time.now}: Done"

