# frozen_string_literal: true

require 'optparse'
require 'yaml'
require 'find'

##
# Module forms and provides runners with the configuration
# about the environment and the application to run.
module Config
  ##
  # Try to find the name of the application that should be tested.
  def self.find_app_name
    if (spec_file = find_file('.spec'))
      name = File.open(spec_file).each_line do |line|
        break line.match(/^Name:\s*(.*)\s*$/)[1] if line =~ /^Name:/
      end
      return name if name
    end
    if (yaml_file = find_file('.yaml'))
      data = YAML.safe_load(File.read(yaml_file))
      return data['Name'] if data.key?('Name')
    end
    ''
  end

  # Find path to the file based on the extension
  # @param extension [String] extension to look for
  # @return [String] path to the file or nil
  def self.find_file(extension)
    Find.find('.') do |path|
      break path if path.end_with?(extension)
    end
  end

  # The name of the configuration file to load parameters from.
  # Theese parameters are overriden when the arguments.
  CONFIGURATION_FILE = '.tests.yaml'

  ##
  # Form the options from the
  # * configuration file
  # * parameters passed to the application
  # * automatic configuration
  # * defaults
  def self.load_options
    options = {
      shutdown_vm: false,
      output_to_file: false,
      tests: [],
      labels: [],
      file: '',
      arguments: '',
      clean: false,
      build: :debug,
      arch: :armv7hl,
      name: '',
      provider: :sailfish,
      sign: false,
      customer_sign: false,
      customer_cert_file: 'packages-client-cert.pem',
      cert_password: 'password',
    }

    if File.readable?(CONFIGURATION_FILE)
      configuration = YAML.safe_load(File.read(CONFIGURATION_FILE))
      options.each_key do |key|
        str_key = key.to_s
        options[key] = configuration[str_key] if configuration.key?(str_key)
      end
    end

    # Parse options of the application
    parser = OptionParser.new do |opts|
      opts.banner = <<~INFO
        Usage: #{$PROGRAM_NAME} [options]
      INFO

      opts.on('-n', '--name NAME', String, 'Specify NAME of the application') do |name|
        options[:name] = name
      end

      opts.on('-i', '--[no-]-integration', 'Run tests integration / user environment. ' \
                                           'In user mode does not stop VMs and shows output for the uer') do |integration_mode|
        options[:shutdown_vm] = integration_mode
        options[:output_to_file] = integration_mode
      end

      opts.on('--save-to-file', 'Save tests results into the file system, do not provide them to the stdout') do
        options[:output_to_file] = true
      end

      opts.on('-t', '--test NAME', String, 'Name of the test application to execute') do |test_name|
        options[:tests].select! do |test|
          test['name'] == test_name
        end
      end

      opts.on('-l', '--labels LABELS', String, 'List of test labels that should be run separated by comas') do |labels|
        break if labels.empty?

        label_list = labels.split(',')
        options[:tests].reject! do |test|
          common_labels = test['labels'] & label_list
          common_labels.empty?
        end
      end

      opts.on('-f', '--file FILE', String, 'Path to the file containing that will be executed') do |file|
        options[:file] = file
      end

      opts.on('-a', '--arguments ARGUMENTS', String, 'Arguments that should be passed to the test runner') do |arguments|
        options[:arguments] = arguments
      end

      opts.on('-b', '--build TYPE', %i[debug release], 'Type of the application to build, debug or release. Debug by default') do |build|
        options[:build] = build.to_sym
      end

      opts.on('--arch ARCHITECTURE ', %i[i486 armv7hl], 'Architecture type. ARM by default') do |arch|
        options[:arch] = arch
      end

      opts.on('-c', '--clean', 'Perform clean build. false by default') do |clean|
        options[:clean] = clean
      end

      opts.on('--provider PROVIDER', %i[sailfish aurora], 'VM Build Provider. Sailfish by default') do |provider|
        options[:provider] = provider
      end

      opts.on('--sign', 'Sign build packages with OMP tools') do |sign|
        options[:sign] = sign
      end

      opts.on('--customer-sign', 'Sign build packages with our certificate as client') do |sign|
        options[:customer_sign] = sign
      end

      opts.on('--cert-password', 'Password for the certificate') do |password|
        options[:cert_password] = password
      end

      opts.on('--customer-cert-name', 'Name of the customer certificate to use') do |cert|
        options[:customer_cert_file] = cert
      end
    end
    parser.parse!

    # Try to automatically detect application name
    options[:name] = find_app_name if options[:name].empty?

    # Provide configuration to the calling method
    options
  end
end
