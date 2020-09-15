# frozen_string_literal: true

require 'net/ssh'
require_relative 'errors'

# This module provides a support method that is able
# not only to execute command, but capture the
# status of the executed command
module TestRunner
  module SSH
    def self.exec!(ssh, directory, command, input_data='')
      stdout_data = ''
      stderr_data = ''
      exit_code = nil
      exit_signal = nil
      ssh.open_channel do |channel|
        channel.request_pty
        channel.send_channel_request "shell" do |_ch, success|
          break unless success
          channel.send_data("cd #{directory} && #{command} <<< \"#{input_data}\"\n")
          channel.send_data("exit $?\n")
        end

        channel.on_data do |_ch, data|
          stdout_data += data
        end

        channel.on_extended_data do |_ch, _type, data|\
          stderr_data += data
        end

        channel.on_request('exit-status') do |_ch, data|
          exit_code = data.read_long
        end

        channel.on_request('exit-signal') do |_ch, data|
          exit_signal = data.read_long
        end
      end
      ssh.loop
      [stdout_data, stderr_data, exit_code, exit_signal]
    end

    def self.checked_exec!(session, directory, command, input_data='')
      data, error, code, _ = exec!(session, directory, command, input_data)
      if code != 0
        raise SSHCommandError, "Error during #{command} execution. \n#{data}\n#{error}\n in #{directory} directory"
      end
      data
    end

    def self.simple_exec!(ssh, command, input_data='')
      stdout_data = ''
      stderr_data = ''
      exit_code = nil
      exit_signal = nil
      ssh.open_channel do |channel|
        channel.exec(command.to_s) do |_ch, success|
          abort "FAILED: couldn't execute command (ssh.channel.exec)" unless success

          channel.on_data do |_ch, data|
            stdout_data += data
          end

          channel.on_extended_data do |_ch, _type, data|
            stderr_data += data
          end

          channel.on_request('exit-status') do |_ch, data|
            exit_code = data.read_long
          end

          channel.on_request('exit-signal') do |_ch, data|
            exit_signal = data.read_long
          end

          channel.send_data("#{input_data}\n")
        end
      end
      ssh.loop
      [stdout_data, stderr_data, exit_code, exit_signal]
    end
  end
end
