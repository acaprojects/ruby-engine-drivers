# frozen_string_literal: true

module Cisco; end
module Cisco::Spark; end
module Cisco::Spark::Xapi; end

# Regexp's for tokenizing the xAPI command and response structure.
module Cisco::Spark::Xapi::Tokens
    JSON_RESPONSE ||= /(?<=^})|(?<=^{})[\r\n]+/

    INVALID_COMMAND ||= /(?<=^Command not recognized\.)[\r\n]+/

    SUCCESS ||= /(?<=^OK)[\r\n]+/

    COMMAND_RESPONSE ||= Regexp.union([JSON_RESPONSE, INVALID_COMMAND, SUCCESS])

    LOGIN_COMPLETE ||= /\*r Login successful[\r\n]+/
end
