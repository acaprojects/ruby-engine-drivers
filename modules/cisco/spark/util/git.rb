# frozen_string_literal: true

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Util; end

module Cisco::Spark::Util::Git
    module_function

    # Get the commit hash for the passed path.
    #
    # @param path [String] the path to the repo
    # @return [String, nil] the short commit hash
    def hash(path)
        Dir.chdir(path) { `git rev-parse --short HEAD`.strip } if installed?
    end

    # Check if git is installed and accessible to the curent process.
    #
    # @return [Boolean]
    def installed?
        system 'git --version'
    end
end
