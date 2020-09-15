# frozen_string_literal: true

module TestRunner
  # This error is thrown when no VM with such a name was
  # found on this machine
  class VMNotFoundError < StandardError
  end

  # This error is thrown when VM could not start
  class VMDidNotStart < StandardError
  end

  # This error is throws if SSH command was not executed correctly
  class SSHCommandError < StandardError
  end
end
