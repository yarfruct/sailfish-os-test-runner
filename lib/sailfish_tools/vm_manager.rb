# frozen_string_literal: true

require 'find'
require 'English'
require_relative 'errors'

# Class manages virtual machines and provides methods
# to manage their state
class VMManager
  SAILFISH_SDK_TEMPLATE = {
    name: 'Sailfish OS Build Engine',
    config: [
      'localhost',
      'mersdk',
      {
        keys: [],
        port: 2222,
      },
    ],
  }.freeze

  SAILFISH_EMULATOR_TEMPLATE = {
    name: 'Sailfish OS Emulator',
    achitecture: 'i486',
    config: [
      'localhost',
      'nemo',
      {
        keys: [],
        port: 2223,
      },
    ],
  }.freeze

  AURORA_SDK_TEMPLATE = {
    name: 'Aurora Build Engine',
    config: [
      'localhost',
      'mersdk',
      {
        keys: [],
        port: 2222,
      },
    ],
  }.freeze

  AURORA_EMULATOR_TEMPLATE = {
    name: 'Aurora Emulator',
    achitecture: 'i486',
    config: [
      'localhost',
      'nemo',
      {
        keys: [],
        port: 2223,
      },
    ],
  }.freeze

  PROVIDERS = {
    aurora: {
      emulator: AURORA_EMULATOR_TEMPLATE,
      sdk: AURORA_SDK_TEMPLATE,
    },
    sailfish: {
      emulator: SAILFISH_EMULATOR_TEMPLATE,
      sdk: SAILFISH_SDK_TEMPLATE,
    },
  }.freeze

  def initialize(vm_provider)
    tools = PROVIDERS[vm_provider]
    determine_vm_configuration
    determine_vmshare_directory(tools[:sdk][:name])
    @sdk_vm = print_template(tools[:sdk])
    @emulator = print_template(tools[:emulator])
  end

  def start_sdk
    start_vm(@sdk_vm)
  end

  def start_emulator(headless = true)
    start_vm(@emulator, headless)
  end

  def shutdown_sdk
    shutdown_vm(@sdk_vm)
  end

  def shutdown_emulator
    shutdown_vm(@emulator)
  end

  def sdk_ssh_config
    @sdk_vm[:config]
  end

  def emulator_ssh_config
    @emulator[:config]
  end

  def sdk_rsync_config
    ssh_config = sdk_ssh_config[2]
    "ssh -p #{ssh_config[:port]} -i #{ssh_config[:keys][0]}"
  end

  def sdk_network_location
    sdk_config = sdk_ssh_config
    "#{sdk_config[1]}@#{sdk_config[0]}"
  end

  private

  VBOXMANAGER_VM_LIST = /^"(.*)" \{(.*)\}$/.freeze

  # Method tries to detect the Sailfish OS VM configuration
  def determine_vm_configuration
    @machines = `VBoxManage list vms`.each_line.map do |line|
      parts = VBOXMANAGER_VM_LIST.match(line)
      { name: parts[1], id: parts[2] }
    end
  end

  def determine_vmshare_directory(sdk_name)
    machine_info = @machines.find { |machine| machine[:name].include?(sdk_name) }
    vm_info = `VBoxManage showvminfo --machinereadable #{machine_info[:id]}`.each_line.select do |params|
      params.include?('SharedFolder') && params.include?('vmshare')
    end
    raise 'Unable to detect the path to VM configuration!' if vm_info.empty?

    @vmshare_dir = File.join(vm_info[0].strip.split('=')[1].delete('"'), 'ssh', 'private_keys')
    unless File.directory?(@vmshare_dir)
      raise "The detected vmshare directory #{@vmshare_dir} does not exist!"
    end
  end

  # Modify paths to the ssh keys in the VM configuration
  def print_template(template)
    machine_info = @machines.find { |machine| machine[:name].include?(template[:name]) }
    config = template.merge(machine_info)
    Find.find(@vmshare_dir) do |file|
      next unless File.basename(file) == config[:config][1]

      config[:config].last[:keys].push(file)
    end
    if config[:config].last[:keys].empty?
      raise "Unable to find keys to the machine '#{config[:name]}' in '#{@vmshare_dir}'"
    end

    config[:config].last[:verify_host_key] = :never
    config
  end

  # Starts the VirtualBox virtual machine specified by the name
  # if the machine is not available, then throws the
  # corresponding exception with description.
  #
  # Then method tries to connect to it via ssh several times
  # with the timeout. If it fails, then the VM was not able
  # to start and we can not connect to it.
  # Application throws connection timeout exception.
  #
  # @param vm_config [Hash] configuration of the Virtual Machine from
  #   VIRTUAL_MACHINES set.
  def start_vm(vm_config, headless = true)
    puts "Starting #{vm_config[:name]} virtual machine"
    check_vm_for_existence(vm_config[:name])
    check_or_start_vm(vm_config, headless)
    wait_for_wm_to_boot(vm_config[:config])
  end

  # Check that corresponding VM is listed as installed VM
  def check_vm_for_existence(name)
    vms = `VBoxManage list vms`
    unless vms.include?(name)
      raise TestRunner::VMNotFoundError.new, "Machine '#{name}' is not installed"
    end
  end

  # Check that VM is running, if not, start it in
  # mode depending on headless argument value
  def check_or_start_vm(config, headless)
    vms = `VBoxManage list runningvms`
    return if vms.include?(config[:id])

    options = headless ? '--type headless' : ''
    `VBoxManage startvm "#{config[:id]}" #{options}`

    unless $CHILD_STATUS.success?
      raise TestRunner::VMDidNotStart.new, "Machine '#{config[:name]}' did not start"
    end
  end

  # Check that VM has been started by connecting via SSH
  def wait_for_wm_to_boot(ssh_config)
    puts 'Checking that VM responds to SSH connection'
    Net::SSH.start(*ssh_config) {}
  end

  # Gracefully shutdown VM
  def shutdown_vm(vm_config)
    puts "Shutting down VM #{vm_config[:name]}"
    `VBoxManage controlvm "#{vm_config[:id]}" acpipowerbutton`
    loop do
      vms = `VBoxManage list runningvms`
      return unless vms.include?(vm_config[:id])

      sleep(2)
    end
  end
end
