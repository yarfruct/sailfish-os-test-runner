# frozen_string_literal: true

require_relative 'sailfish_tools/errors'
require_relative 'sailfish_tools/ssh'
require_relative 'sailfish_tools/config'
require_relative 'sailfish_tools/vm_manager'

require 'net/ssh'
require 'net/scp'
require 'fileutils'

# Core module that provides all required functionality
module SailfishTools
  # Path of the home directory on the SDK machine
  BASE_PATH = '/home/mersdk/share'

  # Architectures to compile project
  X86 = 'i486'
  ARM = 'armv7hl'

  # Compile project on the SDK and provide path to
  # the generated RPM file
  def self.compile_project(ssh_config, provider, architecture, build = :debug, clean_build = false)
    puts 'Building project using SDK'

    # Configuring the toolchain and build directory based
    # upon the architecture and debug mode
    local_build_path = File.join('build', provider.to_s, architecture.to_s)
    if build == :debug
      local_build_path = File.join(local_build_path, 'debug')
      flags = '--with debug'
    else
      local_build_path = File.join(local_build_path, 'release')
      flags = ''
    end

    # Perform all steps required for the complication
    vm_path = File.join(BASE_PATH, Dir.pwd.sub(Dir.home, ''))
    build_path = File.join(vm_path, local_build_path)
    Net::SSH.start(*ssh_config) do |session|
      # Trying to get toolchain based on the architecture
      toolchains, _, _, _ = TestRunner::SSH.simple_exec!(session,"sb2-config -l | grep #{architecture}")
      toolchain = toolchains.lines.first.strip
      puts "Using toolchain: #{toolchain}"

      TestRunner::SSH.simple_exec!(session, "rm -rf #{build_path}") if clean_build
      TestRunner::SSH.simple_exec!(session, "mkdir -p #{build_path}")
      TestRunner::SSH.simple_exec!(session, "specify #{vm_path}/rpm/*.yaml")
      TestRunner::SSH.checked_exec!(session, vm_path, "mb2 -t #{toolchain} installdeps")
      TestRunner::SSH.checked_exec!(session, build_path, "mb2 -t #{toolchain} build ../../../.. #{flags}")
      TestRunner::SSH.checked_exec!(session, build_path, "mb2 -t #{toolchain} rpm")
    end

    # Find the RPM file in the required directory and exclude debug ones
    Dir.glob("#{local_build_path}/RPMS/*.rpm")
       .reject { |file| file.include?('debuginfo') || file.include?('debugsource') }
       .sort
  end

  # Install archive on the target device
  # Currently only emulator is supported
  # @param device_config SSH configuration to connect to device
  # @param file_paths [Array<String>] paths to the archive to install
  def self.install_archive(device_config, file_paths)
    puts 'Installing application on the device'
    remote_paths = file_paths.map do |path|
      file_name = File.basename(path)
      remote_path = File.join('/tmp', file_name)
      Net::SCP.upload!(device_config[0], device_config[1], path, remote_path, ssh: device_config.last)
      remote_path
    end

    Net::SSH.start(*device_config) do |session|
      remote_paths.each do |path|
        package_name, = TestRunner::SSH.simple_exec!(session, "rpm --queryformat '%{NAME}' -qp #{path}")
        TestRunner::SSH.simple_exec!(session, "sudo pkcon remove -y #{package_name}")
      end
      all_files = remote_paths.join(' ')
      TestRunner::SSH.checked_exec!(session, '~',
                                    "sudo pkcon install-local -y #{all_files}")
      TestRunner::SSH.checked_exec!(session, '~', "rm #{all_files}")
    end
  end

  # Install packages qt5-qtdeclarative-import-qttest qt5-qtdeclarative-devel-tools
  # on the virtual machine to run tests
  def self.install_test_packages(device_config)
    puts 'Installing required packages on the device'
    Net::SSH.start(*device_config) do |session|
      %w[qt5-qtdeclarative-import-qttest qt5-qtdeclarative-devel-tools].each do |package|
        TestRunner::SSH.checked_exec!(session, '~', "sudo pkcon install -y #{package}")
      end
    end
  end

  # Run test on the device.
  def self.execute_tests(device_config, options)
    puts 'Running tests'
    FileUtils.rm_rf('test-results')
    FileUtils.mkdir_p('test-results')
    Net::SSH.start(*device_config) do |session|
      options[:tests].each do |test|
        puts "Running test #{test['name']}"
        session.exec!("rm -rf ~/.local/share/#{test['name']}")
        if options[:output_to_file]
          results = session.exec!("#{test['name']} -o -,xunitxml")
          File.write(File.join('test-results', "#{test['name']}.xml"), results)
        else
          puts session.exec!(test['name'])
        end
      end
    end
  end

  # Setup environment SDK for main tools
  def self.setup_environment(start_emulator)
    options = Config.load_options
    manager = VMManager.new(options[:provider])
    manager.start_sdk
    manager.start_emulator(options[:shutdown_vm]) if start_emulator
    result = yield options, manager
    return result unless options[:shutdown_vm]

    manager.shutdown_emulator if start_emulator
    manager.shutdown_sdk
    result
  end

  # Compile the application and start tests
  def self.run_tests
    setup_environment(true) do |options, manager|
      if options[:tests].empty?
        puts 'You did not selected tests to be run on the machine!'
        break false
      end
      files = compile_project(manager.sdk_ssh_config, options[:provider], X86, options[:build], options[:clean])
      install_archive(manager.emulator_ssh_config, files)
      install_test_packages(manager.emulator_ssh_config)
      execute_tests(manager.emulator_ssh_config, options)
    end
    true
  end

  # Compile the application
  def self.build_app
    setup_environment(false) do |options, manager|
      puts format("Performing build\nApplication: %{name}\nArchitecture: %{arch}\n"\
           "Build type: %{build}\nClean build: %{clean}\nSDK Provider: %{provider}", options)
      files = compile_project(manager.sdk_ssh_config, options[:provider], options[:arch],
                              options[:build], options[:clean])
      files.each do |file|
        full_path = File.join(Dir.pwd, file)
        if options[:sign]
          sign_rmp_file(manager.sdk_ssh_config, full_path, options[:cert_password])
        end
        if options[:customer_sign]
          customer_sign_file(manager.sdk_ssh_config, full_path, options[:customer_cert_file],
                             options[:cert_password])
        end
      end
      puts "Files: #{files.join(' ')}"
    end
  end

  # Compile application on the remote machine without the
  def self.compile_app_in_vm(manager, architecture, application_name, build = :debug, clean_build = false)
    puts 'Building current application on the VM'

    relative_path = "~/build/#{application_name}/#{architecture}/#{build}"
    Net::SSH.start(*manager.sdk_ssh_config) do |session|
      build_path = session.exec!("echo #{relative_path}").strip
      # Remove target directory if we want to perform clean build
      if clean_build
        puts 'Performing clean build'
        TestRunner::SSH.simple_exec!(session, "rm -rf #{build_path}")
      end
      puts "Creating #{build_path}"
      TestRunner::SSH.simple_exec!(session, "mkdir -p #{build_path}")
      # Copying all files in current directory to the remote machine
      puts 'Copying local files to remote location'
      command = "rsync -avz -e '#{manager.sdk_rsync_config}' . #{manager.sdk_network_location}:#{build_path}"
      puts "Running #{command}"
      `#{command}`
      # Trying to get toolchain based on the build
      toolchain, _, _, _ = TestRunner::SSH.simple_exec!(session,"sb2-config -l")
      toolchain = toolchain.lines.first.chomp
      puts "Using toolchain: #{toolchain}"
      flags = ''
      flags += '-d' if build == :debug
      # Performing build using mb2
      result = TestRunner::SSH.checked_exec!(session, build_path, "mb2 -t #{toolchain} build #{flags}")
      puts "Bulid result:\n#{result}"
      puts result
      # Copying all the files from the remote machine in RPMS directory to the current machine
      puts 'Downloading created RPM files'
      session.scp.download!("#{build_path}/RPMS/", '.', recursive: true)
    end
  end

  def self.build_app_in_vm
    setup_environment(false) do |options, manager|
      puts format("Performing build\nArchitecture: %{arch}\n"\
           "Build type: %{build}\nClean build: %{clean}", options)
      compile_app_in_vm(manager, options[:arch], options[:name],
                        options[:build], options[:clean])
    end
  end

  def self.sign_rmp_file(ssh_engine_config, local_rpm_path, certificate_password)
    Net::SSH.start(*ssh_engine_config) do |session|
      vm_file_path = File.join(BASE_PATH, local_rpm_path.sub(Dir.home, ''))
      puts("Signing #{local_rpm_path}")
      TestRunner::SSH.checked_exec!(session, BASE_PATH, "customer-sign #{vm_file_path}", certificate_password)
      puts("Successfully signed")
    end
  end

  def self.customer_sign_file(ssh_engine_config, local_rpm_path, certificate_name, certificate_password)
    Net::SSH.start(*ssh_engine_config) do |session|
      vm_file_path = File.join(BASE_PATH, local_rpm_path.sub(Dir.home, ''))
      puts("Customer signing #{local_rpm_path}")
      TestRunner::SSH.checked_exec!(session, BASE_PATH,
                                    "ompcert-cli sign #{vm_file_path} ~/share/.mersdk/packages-key.pem ~/share/.mersdk/#{certificate_name}",
                                    certificate_password)
      puts("Successfully added customer signature")
    end
  end
end
