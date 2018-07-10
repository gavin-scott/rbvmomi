# Copyright (c) 2011-2017 VMware, Inc.  All Rights Reserved.
# SPDX-License-Identifier: MIT

# Based on takeVMScreenshot.pl by William Lam
require 'trollop'
require 'rbvmomi'
require 'rbvmomi/trollop'

VIM = RbVmomi::VIM

opts = Trollop.options do
  banner <<-EOS
Take a screenshot.

Usage:
    guest_command.rb [options] vm filename

Will execute a guest os command

VIM connection options:
    EOS

    rbvmomi_connection_opts

    text <<-EOS

VM location options:
    EOS

    rbvmomi_datacenter_opt

    text <<-EOS

Other options:
  EOS
end

Trollop.die("must specify host") unless opts[:host]
vm_name = ARGV[0] or abort("must specify VM name")
command = ARGV[1] or abort("must specify command to run")
args = ARGV.slice(2, ARGV.length)

vim = VIM.connect opts
dc = vim.serviceInstance.find_datacenter(opts[:datacenter])
vm = dc.find_vm vm_name
abort "VM must be running" unless vm.runtime.powerState == 'poweredOn'

# Related API docs: https://pubs.vmware.com/vsphere-51/index.jsp?topic=%2Fcom.vmware.wssdk.apiref.doc%2Fvim.vm.guest.ProcessManager.html
# Related sample code: https://github.com/chef-partners/knife-vsphere/blob/master/lib/chef/knife/vsphere_vm_execute.rb
#
gom = vim.serviceContent.guestOperationsManager

# WARNING: guest creds are hard-coded as root / admin
guest_auth = RbVmomi::VIM::NamePasswordAuthentication(:interactiveSession => false,
                                                      :username => "root",
                                                      :password => "admin")

# WARNING: working directory is hard-coded as /root
prog_spec = RbVmomi::VIM::GuestProgramSpec(:programPath => command,
                                           :arguments => args.join(" "),
                                           :workingDirectory => "/root")

# Execute command
pid = gom.processManager.StartProgramInGuest(:vm => vm, :auth => guest_auth, :spec => prog_spec)

puts "Got pid #{pid}"

# Poll for completion
exit_code = nil
until exit_code
  results = gom.processManager.ListProcessesInGuest(:vm => vm, :auth => guest_auth, :pids => [pid])
  raise("Failed to look up process id %d results " % pid) unless results && results.size == 1

  exit_code = results.first.exitCode

  unless exit_code
    puts "Waiting for process to exit..."
    sleep(1)
  end
end

raise("Process failed with exit code %d" % exit_code) unless exit_code == 0
