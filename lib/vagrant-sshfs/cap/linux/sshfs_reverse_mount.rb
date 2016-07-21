require "log4r"
require "vagrant/util/retryable"
require "tempfile"

# This is already done for us in lib/vagrant-sshfs.rb. We needed to
# do it there before Process.uid is called the first time by Vagrant
# This provides a new Process.create() that works on Windows.
if Vagrant::Util::Platform.windows?
  require 'win32/process'
end

module VagrantPlugins
  module GuestLinux
    module Cap
      class MountSSHFS
        extend Vagrant::Util::Retryable
        @@logger = Log4r::Logger.new("vagrant::synced_folders::sshfs_mount")

        def self.reverse_sshfs_is_folder_mounted(machine, opts)
          mounted = false
          hostpath = opts[:hostpath].dup
          hostpath.gsub!("'", "'\\\\''")
          hostpath = hostpath.chomp('/') # remove trailing / if exists
          cat_cmd = Vagrant::Util::Which.which('cat')
          result = Vagrant::Util::Subprocess.execute(cat_cmd, '/proc/mounts')
          result.stdout.each_line do |line|
            splitis = line.split()[1]
            machine.ui.info("Line is #{splitis}. Hostpath is #{hostpath}")
            if line.split()[1] == hostpath
              mounted = true
              break
            end
          end

##        machine.communicate.execute("cat /proc/mounts") do |type, data|
##          if type == :stdout
##            data.each_line do |line|
##              if line.split()[1] == expanded_guest_path
##                mounted = true
##                break
##              end
##            end
##          end
##        end
          return mounted
        end

        def self.reverse_sshfs_mount_folder(machine, opts)
          # opts contains something like:
          #   { :type=>:sshfs,
          #     :guestpath=>"/sharedfolder",
          #     :hostpath=>"/guests/sharedfolder", 
          #     :disabled=>false
          #     :ssh_host=>"192.168.1.1"
          #     :ssh_port=>"22"
          #     :ssh_username=>"username"
          #     :ssh_password=>"password"
          #   }
          if self.reverse_sshfs_is_folder_mounted(machine, opts)
            print("Is mounted")
          else
            print("Is not mounted")
          end
          self.sshfs_slave_mount(machine, opts)
        end

        protected

        # Perform a mount by running an sftp-server on the vagrant host 
        # and piping stdin/stdout to sshfs running inside the guest
        def self.sshfs_slave_mount(machine, opts)

         #sftp_server_path = opts[:sftp_server_exe_path]
          sftp_server_path = '/usr/libexec/openssh/sftp-server'
         #ssh_path = opts[:ssh_exe_path]
          ssh_path = '/usr/bin/ssh'
          sshfs_path = '/usr/bin/sshfs'


          # expand the guest path so we can handle things like "~/vagrant"
          expanded_guest_path = machine.guest.capability(
            :shell_expand_guest_path, opts[:guestpath])

          # Mount path information
          hostpath = opts[:hostpath].dup
          hostpath.gsub!("'", "'\\\\''")

          # Add in some sshfs/fuse options that are common to both mount methods
          opts[:sshfs_opts] = ' -o noauto_cache '# disable caching based on mtime

          # Add in some ssh options that are common to both mount methods
          opts[:ssh_opts] = ' -o StrictHostKeyChecking=no '# prevent yes/no question 
          opts[:ssh_opts]+= ' -o ServerAliveInterval=30 '  # send keepalives

          # SSH connection options
          ssh_opts = opts[:ssh_opts]
          ssh_opts_append = opts[:ssh_opts_append].to_s # provided by user

          # SSHFS executable options
          sshfs_opts = opts[:sshfs_opts]
          sshfs_opts_append = opts[:sshfs_opts_append].to_s # provided by user

          # The sftp-server command
          sftp_server_cmd_from_guest = sftp_server_path

          # The local sshfs command (in slave mode)
          sshfs_opts+= ' -o slave '
          sshfs_cmd = sshfs_path
          sshfs_cmd+= " :#{expanded_guest_path} #{hostpath}" 
          sshfs_cmd+= sshfs_opts + ' ' + sshfs_opts_append + ' '

          # The remote sftp-server command that will run
          # XXX need to detect where sftp_server is in the guest
          sftp_server_cmd = sftp_server_path

          # The ssh command to connect to guest and then launch sftp-server
          ssh_opts = opts[:ssh_opts]
          ssh_opts+= ' -o User=' + machine.ssh_info[:username]
          ssh_opts+= ' -o Port=' + machine.ssh_info[:port].to_s
          ssh_opts+= ' -o IdentityFile=' + machine.ssh_info[:private_key_path][0]
          ssh_opts+= ' -o UserKnownHostsFile=/dev/null '
          ssh_opts+= ' -F /dev/null ' # Don't pick up options from user's config
          ssh_cmd = ssh_path + ssh_opts + ' ' + ssh_opts_append + ' ' + machine.ssh_info[:host]
          ssh_cmd+= ' "' + sftp_server_cmd + '"'

          # Log some information
          @@logger.debug("sshfs cmd: #{sshfs_cmd}")
          @@logger.debug("ssh cmd: #{ssh_cmd}")
          machine.ui.info(I18n.t("vagrant.sshfs.actions.slave_mounting_folder", 
                          hostpath: hostpath, guestpath: expanded_guest_path))

          # Create two named pipes for communication between sftp-server and
          # sshfs running in slave mode
          r1, w1 = IO.pipe # reader/writer from pipe1
          r2, w2 = IO.pipe # reader/writer from pipe2

          # Log STDERR to predictable files so that we can inspect them
          # later in case things go wrong. We'll use the machines data
          # directory (i.e. .vagrant/machines/default/virtualbox/) for this
          f1path = machine.data_dir.join('vagrant_sshfs_sftp_server_stderr.txt')
          f2path = machine.data_dir.join('vagrant_sshfs_sshfs_stderr.txt')
          f1 = File.new(f1path, 'w+')
          f2 = File.new(f2path, 'w+')

          # The way this works is by hooking up the stdin+stdout of the
          # sftp-server process to the stdin+stdout of the sshfs process
          # running inside the guest in slave mode. An illustration is below:
          # 
          #          stdout => w1      pipe1         r1 => stdin 
          #         />------------->==============>----------->\
          #        /                                            \
          #        |                                            |
          #    sftp-server (on vm host)                      sshfs (inside guest)
          #        |                                            |
          #        \                                            /
          #         \<-------------<==============<-----------</
          #          stdin <= r2        pipe2         w2 <= stdout 
          #
          # Wire up things appropriately and start up the processes
          if Vagrant::Util::Platform.windows?
            # Need to handle Windows differently. Kernel.spawn fails to work, if the shell creating the process is closed.
            # See https://github.com/dustymabe/vagrant-sshfs/issues/31
            Process.create(:command_line => ssh_cmd,
                           :creation_flags => Process::DETACHED_PROCESS,
                           :process_inherit => false,
                           :thread_inherit => true,
                           :startup_info => {:stdin => w2, :stdout => r1, :stderr => f1})

            Process.create(:command_line => sshfs_cmd,
                           :creation_flags => Process::DETACHED_PROCESS,
                           :process_inherit => false,
                           :thread_inherit => true,
                           :startup_info => {:stdin => w1, :stdout => r2, :stderr => f2})
          else
            p1 = spawn(ssh_cmd,   :out => w2, :in => r1, :err => f1, :pgroup => true)
            p2 = spawn(sshfs_cmd, :out => w1, :in => r2, :err => f2, :pgroup => true)

            # Detach from the processes so they will keep running
            Process.detach(p1)
            Process.detach(p2)
          end

          # Check that the mount made it
          mounted = false
          for i in 0..6
            machine.ui.info("Checking Mount..")
            if self.reverse_sshfs_is_folder_mounted(machine, opts)
              mounted = true
              break
            end
            sleep(2)
          end
          if !mounted
            f1.rewind # Seek to beginning of the file
            f2.rewind # Seek to beginning of the file
            error_class = VagrantPlugins::SyncedFolderSSHFS::Errors::SSHFSReverseMountFailed
            raise error_class, sftp_stderr: f1.read, sshfs_stderr: f2.read
          end
          machine.ui.info("Folder Successfully Mounted!")
        end
      end
    end
  end
end
