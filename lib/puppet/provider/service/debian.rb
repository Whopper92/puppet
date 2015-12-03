# Manage debian services.  Start/stop is the same as InitSvc, but enable/disable
# is special.
Puppet::Type.type(:service).provide :debian, :parent => :init do
  desc <<-EOT
    Debian's form of `init`-style management.

    The only differences from `init` are support for enabling and disabling
    services via `update-rc.d` and the ability to determine enabled status via
    `invoke-rc.d`.

  EOT

  commands :update_rc => "/usr/sbin/update-rc.d"
  # note this isn't being used as a command until
  # http://projects.reductivelabs.com/issues/2538
  # is resolved.
  commands :invoke_rc => "/usr/sbin/invoke-rc.d"
  commands :service_cmd => "/usr/sbin/service"
  optional_commands :systemctl => "/bin/systemctl"

  defaultfor :operatingsystem => :cumuluslinux
  defaultfor :operatingsystem => :debian, :operatingsystemmajrelease => ['5','6','7']

  def self.supports_systemd?
    Puppet::FileSystem.exist?(Puppet::FileSystem.dir("/run/systemd/system"))
  end

  def is_sysv_unit?
    # The sysv generator sets the SourcePath attribute to the name of the
    # initscript. Use this to detect whether a unit is backed by an initscript
    # or not.
    source = systemctl(:show, "-pSourcePath", @resource[:name].gsub('@', ''))
    source.start_with? "SourcePath=/etc/init.d/"
  end

  def self.instances
    # We need to merge services with systemd unit files with those only having
    # an initscript. Note that we could use `systemctl --all` to get sysv
    # services as well, however it would only output *enabled* services.
    i = {}
    if self.supports_systemd?
      begin
        output = systemctl('list-unit-files', '--type', 'service', '--full', '--all',  '--no-pager')
        output.scan(/^(\S+)\.service\s+(disabled|enabled)\s*$/i).each do |m|
          i[m[0]] = new(:name => m[0])
        end
      rescue Puppet::ExecutionFailure
      end
    end
    get_services(defpath).each do |sysv|
      unless i.has_key?(sysv.name)
        i[sysv.name] = sysv
      end
    end
    return i.values
  end

  # Remove the symlinks
  def disable
    if self.class.supports_systemd?
      systemctl(:disable, @resource[:name])
    else
      update_rc @resource[:name], "disable"
    end
  end

  def enabled?
    # Initscript-backed services have no enabled status in systemd, so we
    # need to query them using invoke-rc.d.
    if self.class.supports_systemd? and not is_sysv_unit?
      begin
        systemctl("is-enabled", @resource[:name])
        return :true
      rescue Puppet::ExecutionFailure
        return :false
      end
    else
      # TODO: Replace system call when Puppet::Util::Execution.execute gives us a way
      # to determine exit status.  http://projects.reductivelabs.com/issues/2538
      system("/usr/sbin/invoke-rc.d", "--quiet", "--query", @resource[:name], "start")

      # 104 is the exit status when you query start an enabled service.
      # 106 is the exit status when the policy layer supplies a fallback action
      # See x-man-page://invoke-rc.d
      if [104, 106].include?($CHILD_STATUS.exitstatus)
        return :true
      elsif [105].include?($CHILD_STATUS.exitstatus)
        # 105 is unknown, which generally means the iniscript does not support query
        # The debian policy states that the initscript should support methods of query
        # For those that do not, peform the checks manually
        # http://www.debian.org/doc/debian-policy/ch-opersys.html
        if get_start_link_count >= 4
          return :true
        else
          return :false
        end
      else
        return :false
      end
    end
  end

  def get_start_link_count
    Dir.glob("/etc/rc*.d/S??#{@resource[:name]}").length
  end

  def enable
    if self.class.supports_systemd?
      systemctl(:enable, @resource[:name])
    else
      update_rc @resource[:name], "enable"
    end
  end

  # The start, stop, restart and status command use service
  # this makes sure that these commands work with whatever init
  # system is installed
  def startcmd
    [command(:service), @resource[:name], :start]
  end

  # The stop command is just the init script with 'stop'.
  def stopcmd
    [command(:service_cmd), @resource[:name], :stop]
  end

  def restartcmd
    (@resource[:hasrestart] == :true) && [command(:service_cmd), @resource[:name], :restart]
  end

  # If it was specified that the init script has a 'status' command, then
  # we just return that; otherwise, we return false, which causes it to
  # fallback to other mechanisms.
  def statuscmd
    (@resource[:hasstatus] == :true) && [command(:service_cmd), @resource[:name], :status]
  end
end
