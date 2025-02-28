# frozen_string_literal: true

require 'forwardable'

require_relative 'constants'
require_relative 'utils'

module Rack
  # Rack::Lint validates your application and the requests and
  # responses according to the Rack spec.

  class Lint
    def initialize(app)
      @app = app
    end

    # :stopdoc:

    class LintError < RuntimeError; end

    ## This specification aims to formalize the Rack protocol. You
    ## can (and should) use Rack::Lint to enforce it.
    ##
    ## When you develop middleware, be sure to add a Lint before and
    ## after to catch all mistakes.
    ##
    ## = Rack applications
    ##
    ## A Rack application is a Ruby object (not a class) that
    ## responds to +call+.
    def call(env = nil)
      Wrapper.new(@app, env).response
    end

    class Wrapper
      def initialize(app, env)
        @app = app
        @env = env
        @response = nil
        @head_request = false

        @status = nil
        @headers = nil
        @body = nil
        @invoked = nil
        @content_length = nil
        @closed = false
        @size = 0
      end

      def response
        ## It takes exactly one argument, the *environment*
        raise LintError, "No env given" unless @env
        check_environment(@env)

        @env[RACK_INPUT] = InputWrapper.new(@env[RACK_INPUT])
        @env[RACK_ERRORS] = ErrorWrapper.new(@env[RACK_ERRORS])

        ## and returns an Array of exactly three values:
        @response = @app.call(@env)
        raise LintError, "response is not an Array, but #{@response.class}" unless @response.kind_of? Array
        raise LintError, "response array has #{@response.size} elements instead of 3" unless @response.size == 3

        @status, @headers, @body = @response
        ## The *status*,
        check_status(@status)

        ## the *headers*,
        check_headers(@headers)

        hijack_proc = check_hijack_response(@headers, @env)
        if hijack_proc && @headers.is_a?(Hash)
          @headers[RACK_HIJACK] = hijack_proc
        end

        ## and the *body*.
        check_content_type(@status, @headers)
        check_content_length(@status, @headers)
        @head_request = @env[REQUEST_METHOD] == HEAD

        @lint = (@env['rack.lint'] ||= []) << self

        if (@env['rack.lint.body_iteration'] ||= 0) > 0
          raise LintError, "Middleware must not call #each directly"
        end

        return [@status, @headers, self]
      end

      ##
      ## == The Environment
      ##
      def check_environment(env)
        ## The environment must be an unfrozen instance of Hash that includes
        ## CGI-like headers. The Rack application is free to modify the
        ## environment.
        raise LintError, "env #{env.inspect} is not a Hash, but #{env.class}" unless env.kind_of? Hash
        raise LintError, "env should not be frozen, but is" if env.frozen?

        ##
        ## The environment is required to include these variables
        ## (adopted from {PEP 333}[https://peps.python.org/pep-0333/]), except when they'd be empty, but see
        ## below.

        ## <tt>REQUEST_METHOD</tt>:: The HTTP request method, such as
        ##                           "GET" or "POST". This cannot ever
        ##                           be an empty string, and so is
        ##                           always required.

        ## <tt>SCRIPT_NAME</tt>:: The initial portion of the request
        ##                        URL's "path" that corresponds to the
        ##                        application object, so that the
        ##                        application knows its virtual
        ##                        "location". This may be an empty
        ##                        string, if the application corresponds
        ##                        to the "root" of the server.

        ## <tt>PATH_INFO</tt>:: The remainder of the request URL's
        ##                      "path", designating the virtual
        ##                      "location" of the request's target
        ##                      within the application. This may be an
        ##                      empty string, if the request URL targets
        ##                      the application root and does not have a
        ##                      trailing slash. This value may be
        ##                      percent-encoded when originating from
        ##                      a URL.

        ## <tt>QUERY_STRING</tt>:: The portion of the request URL that
        ##                         follows the <tt>?</tt>, if any. May be
        ##                         empty, but is always required!

        ## <tt>SERVER_NAME</tt>:: When combined with <tt>SCRIPT_NAME</tt> and
        ##                        <tt>PATH_INFO</tt>, these variables can be
        ##                        used to complete the URL. Note, however,
        ##                        that <tt>HTTP_HOST</tt>, if present,
        ##                        should be used in preference to
        ##                        <tt>SERVER_NAME</tt> for reconstructing
        ##                        the request URL.
        ##                        <tt>SERVER_NAME</tt> can never be an empty
        ##                        string, and so is always required.

        ## <tt>SERVER_PORT</tt>:: An optional +Integer+ which is the port the
        ##                        server is running on. Should be specified if
        ##                        the server is running on a non-standard port.

        ## <tt>SERVER_PROTOCOL</tt>:: A string representing the HTTP version used
        ##                            for the request.

        ## <tt>HTTP_</tt> Variables:: Variables corresponding to the
        ##                            client-supplied HTTP request
        ##                            headers (i.e., variables whose
        ##                            names begin with <tt>HTTP_</tt>). The
        ##                            presence or absence of these
        ##                            variables should correspond with
        ##                            the presence or absence of the
        ##                            appropriate HTTP header in the
        ##                            request. See
        ##                            {RFC3875 section 4.1.18}[https://tools.ietf.org/html/rfc3875#section-4.1.18]
        ##                            for specific behavior.

        ## In addition to this, the Rack environment must include these
        ## Rack-specific variables:

        ## <tt>rack.version</tt>:: The Array representing this version of Rack
        ##                         See Rack::VERSION, that corresponds to
        ##                         the version of this SPEC.

        ## <tt>rack.url_scheme</tt>:: +http+ or +https+, depending on the
        ##                            request URL.

        ## <tt>rack.input</tt>:: See below, the input stream.

        ## <tt>rack.errors</tt>:: See below, the error stream.

        ## <tt>rack.hijack?</tt>:: present and true if the server supports
        ##                         connection hijacking. See below, hijacking.

        ## <tt>rack.hijack</tt>:: an object responding to #call that must be
        ##                        called at least once before using
        ##                        rack.hijack_io.
        ##                        It is recommended #call returns rack.hijack_io
        ##                        as well as setting it in env if necessary.

        ## <tt>rack.hijack_io</tt>:: if rack.hijack? is true, and rack.hijack
        ##                           has received #call, this will contain
        ##                           an object resembling an IO. See hijacking.

        ## Additional environment specifications have approved to
        ## standardized middleware APIs. None of these are required to
        ## be implemented by the server.

        ## <tt>rack.session</tt>:: A hash-like interface for storing
        ##                         request session data.
        ##                         The store must implement:
        if session = env[RACK_SESSION]
          ##                         store(key, value)         (aliased as []=);
          unless session.respond_to?(:store) && session.respond_to?(:[]=)
            raise LintError, "session #{session.inspect} must respond to store and []="
          end

          ##                         fetch(key, default = nil) (aliased as []);
          unless session.respond_to?(:fetch) && session.respond_to?(:[])
            raise LintError, "session #{session.inspect} must respond to fetch and []"
          end

          ##                         delete(key);
          unless session.respond_to?(:delete)
            raise LintError, "session #{session.inspect} must respond to delete"
          end

          ##                         clear;
          unless session.respond_to?(:clear)
            raise LintError, "session #{session.inspect} must respond to clear"
          end

          ##                         to_hash (returning unfrozen Hash instance);
          unless session.respond_to?(:to_hash) && session.to_hash.kind_of?(Hash) && !session.to_hash.frozen?
            raise LintError, "session #{session.inspect} must respond to to_hash and return unfrozen Hash instance"
          end
        end

        ## <tt>rack.logger</tt>:: A common object interface for logging messages.
        ##                        The object must implement:
        if logger = env[RACK_LOGGER]
          ##                         info(message, &block)
          unless logger.respond_to?(:info)
            raise LintError, "logger #{logger.inspect} must respond to info"
          end

          ##                         debug(message, &block)
          unless logger.respond_to?(:debug)
            raise LintError, "logger #{logger.inspect} must respond to debug"
          end

          ##                         warn(message, &block)
          unless logger.respond_to?(:warn)
            raise LintError, "logger #{logger.inspect} must respond to warn"
          end

          ##                         error(message, &block)
          unless logger.respond_to?(:error)
            raise LintError, "logger #{logger.inspect} must respond to error"
          end

          ##                         fatal(message, &block)
          unless logger.respond_to?(:fatal)
            raise LintError, "logger #{logger.inspect} must respond to fatal"
          end
        end

        ## <tt>rack.multipart.buffer_size</tt>:: An Integer hint to the multipart parser as to what chunk size to use for reads and writes.
        if bufsize = env[RACK_MULTIPART_BUFFER_SIZE]
          unless bufsize.is_a?(Integer) && bufsize > 0
            raise LintError, "rack.multipart.buffer_size must be an Integer > 0 if specified"
          end
        end

        ## <tt>rack.multipart.tempfile_factory</tt>:: An object responding to #call with two arguments, the filename and content_type given for the multipart form field, and returning an IO-like object that responds to #<< and optionally #rewind. This factory will be used to instantiate the tempfile for each multipart form file upload field, rather than the default class of Tempfile.
        if tempfile_factory = env[RACK_MULTIPART_TEMPFILE_FACTORY]
          raise LintError, "rack.multipart.tempfile_factory must respond to #call" unless tempfile_factory.respond_to?(:call)
          env[RACK_MULTIPART_TEMPFILE_FACTORY] = lambda do |filename, content_type|
            io = tempfile_factory.call(filename, content_type)
            raise LintError, "rack.multipart.tempfile_factory return value must respond to #<<" unless io.respond_to?(:<<)
            io
          end
        end

        ## The server or the application can store their own data in the
        ## environment, too.  The keys must contain at least one dot,
        ## and should be prefixed uniquely.  The prefix <tt>rack.</tt>
        ## is reserved for use with the Rack core distribution and other
        ## accepted specifications and must not be used otherwise.
        ##

        %w[REQUEST_METHOD SERVER_NAME QUERY_STRING SERVER_PROTOCOL
           rack.version rack.input rack.errors].each { |header|
          raise LintError, "env missing required key #{header}" unless env.include? header
        }

        ## The <tt>SERVER_PORT</tt> must be an Integer if set.
        server_port = env["SERVER_PORT"]
        unless server_port.nil? || (Integer(server_port) rescue false)
          raise LintError, "env[SERVER_PORT] is not an Integer"
        end

        ## The <tt>SERVER_NAME</tt> must be a valid authority as defined by RFC7540.
        unless (URI.parse("http://#{env[SERVER_NAME]}/") rescue false)
          raise LintError, "#{env[SERVER_NAME]} must be a valid authority"
        end

        ## The <tt>HTTP_HOST</tt> must be a valid authority as defined by RFC7540.
        unless (URI.parse("http://#{env[HTTP_HOST]}/") rescue false)
          raise LintError, "#{env[HTTP_HOST]} must be a valid authority"
        end

        ## The <tt>SERVER_PROTOCOL</tt> must match the regexp <tt>HTTP/\d(\.\d)?</tt>.
        server_protocol = env['SERVER_PROTOCOL']
        unless %r{HTTP/\d(\.\d)?}.match?(server_protocol)
          raise LintError, "env[SERVER_PROTOCOL] does not match HTTP/\\d(\\.\\d)?"
        end

        ## If the <tt>HTTP_VERSION</tt> is present, it must equal the <tt>SERVER_PROTOCOL</tt>.
        if env['HTTP_VERSION'] && env['HTTP_VERSION'] != server_protocol
          raise LintError, "env[HTTP_VERSION] does not equal env[SERVER_PROTOCOL]"
        end

        ## The environment must not contain the keys
        ## <tt>HTTP_CONTENT_TYPE</tt> or <tt>HTTP_CONTENT_LENGTH</tt>
        ## (use the versions without <tt>HTTP_</tt>).
        %w[HTTP_CONTENT_TYPE HTTP_CONTENT_LENGTH].each { |header|
          if env.include? header
            raise LintError, "env contains #{header}, must use #{header[5, -1]}"
          end
        }

        ## The CGI keys (named without a period) must have String values.
        ## If the string values for CGI keys contain non-ASCII characters,
        ## they should use ASCII-8BIT encoding.
        env.each { |key, value|
          next  if key.include? "."   # Skip extensions
          unless value.kind_of? String
            raise LintError, "env variable #{key} has non-string value #{value.inspect}"
          end
          next if value.encoding == Encoding::ASCII_8BIT
          unless value.b !~ /[\x80-\xff]/n
            raise LintError, "env variable #{key} has value containing non-ASCII characters and has non-ASCII-8BIT encoding #{value.inspect} encoding: #{value.encoding}"
          end
        }

        ## There are the following restrictions:

        ## * <tt>rack.version</tt> must be an array of Integers.
        unless env[RACK_VERSION].kind_of? Array
          raise LintError, "rack.version must be an Array, was #{env[RACK_VERSION].class}"
        end
        ## * <tt>rack.url_scheme</tt> must either be +http+ or +https+.
        unless %w[http https].include?(env[RACK_URL_SCHEME])
          raise LintError, "rack.url_scheme unknown: #{env[RACK_URL_SCHEME].inspect}"
        end

        ## * There must be a valid input stream in <tt>rack.input</tt>.
        check_input env[RACK_INPUT]
        ## * There must be a valid error stream in <tt>rack.errors</tt>.
        check_error env[RACK_ERRORS]
        ## * There may be a valid hijack stream in <tt>rack.hijack_io</tt>
        check_hijack env

        ## * The <tt>REQUEST_METHOD</tt> must be a valid token.
        unless env[REQUEST_METHOD] =~ /\A[0-9A-Za-z!\#$%&'*+.^_`|~-]+\z/
          raise LintError, "REQUEST_METHOD unknown: #{env[REQUEST_METHOD].dump}"
        end

        ## * The <tt>SCRIPT_NAME</tt>, if non-empty, must start with <tt>/</tt>
        if env.include?(SCRIPT_NAME) && env[SCRIPT_NAME] != "" && env[SCRIPT_NAME] !~ /\A\//
          raise LintError, "SCRIPT_NAME must start with /"
        end
        ## * The <tt>PATH_INFO</tt>, if non-empty, must start with <tt>/</tt>
        if env.include?(PATH_INFO) && env[PATH_INFO] != "" && env[PATH_INFO] !~ /\A\//
          raise LintError, "PATH_INFO must start with /"
        end
        ## * The <tt>CONTENT_LENGTH</tt>, if given, must consist of digits only.
        if env.include?("CONTENT_LENGTH") && env["CONTENT_LENGTH"] !~ /\A\d+\z/
          raise LintError, "Invalid CONTENT_LENGTH: #{env["CONTENT_LENGTH"]}"
        end

        ## * One of <tt>SCRIPT_NAME</tt> or <tt>PATH_INFO</tt> must be
        ##   set. <tt>PATH_INFO</tt> should be <tt>/</tt> if
        ##   <tt>SCRIPT_NAME</tt> is empty.
        unless env[SCRIPT_NAME] || env[PATH_INFO]
          raise LintError, "One of SCRIPT_NAME or PATH_INFO must be set (make PATH_INFO '/' if SCRIPT_NAME is empty)"
        end
        ##   <tt>SCRIPT_NAME</tt> never should be <tt>/</tt>, but instead be empty.
        unless env[SCRIPT_NAME] != "/"
          raise LintError, "SCRIPT_NAME cannot be '/', make it '' and PATH_INFO '/'"
        end
      end

      ##
      ## === The Input Stream
      ##
      ## The input stream is an IO-like object which contains the raw HTTP
      ## POST data.
      def check_input(input)
        ## When applicable, its external encoding must be "ASCII-8BIT" and it
        ## must be opened in binary mode, for Ruby 1.9 compatibility.
        if input.respond_to?(:external_encoding) && input.external_encoding != Encoding::ASCII_8BIT
          raise LintError, "rack.input #{input} does not have ASCII-8BIT as its external encoding"
        end
        if input.respond_to?(:binmode?) && !input.binmode?
          raise LintError, "rack.input #{input} is not opened in binary mode"
        end

        ## The input stream must respond to +gets+, +each+, and +read+.
        [:gets, :each, :read].each { |method|
          unless input.respond_to? method
            raise LintError, "rack.input #{input} does not respond to ##{method}"
          end
        }
      end

      class InputWrapper
        def initialize(input)
          @input = input
        end

        ## * +gets+ must be called without arguments and return a string,
        ##   or +nil+ on EOF.
        def gets(*args)
          raise LintError, "rack.input#gets called with arguments" unless args.size == 0
          v = @input.gets
          unless v.nil? or v.kind_of? String
            raise LintError, "rack.input#gets didn't return a String"
          end
          v
        end

        ## * +read+ behaves like IO#read.
        ##   Its signature is <tt>read([length, [buffer]])</tt>.
        ##
        ##   If given, +length+ must be a non-negative Integer (>= 0) or +nil+,
        ##   and +buffer+ must be a String and may not be nil.
        ##
        ##   If +length+ is given and not nil, then this method reads at most
        ##   +length+ bytes from the input stream.
        ##
        ##   If +length+ is not given or nil, then this method reads
        ##   all data until EOF.
        ##
        ##   When EOF is reached, this method returns nil if +length+ is given
        ##   and not nil, or "" if +length+ is not given or is nil.
        ##
        ##   If +buffer+ is given, then the read data will be placed
        ##   into +buffer+ instead of a newly created String object.
        def read(*args)
          unless args.size <= 2
            raise LintError, "rack.input#read called with too many arguments"
          end
          if args.size >= 1
            unless args.first.kind_of?(Integer) || args.first.nil?
              raise LintError, "rack.input#read called with non-integer and non-nil length"
            end
            unless args.first.nil? || args.first >= 0
              raise LintError, "rack.input#read called with a negative length"
            end
          end
          if args.size >= 2
            unless args[1].kind_of?(String)
              raise LintError, "rack.input#read called with non-String buffer"
            end
          end

          v = @input.read(*args)

          unless v.nil? or v.kind_of? String
            raise LintError, "rack.input#read didn't return nil or a String"
          end
          if args[0].nil?
            unless !v.nil?
              raise LintError, "rack.input#read(nil) returned nil on EOF"
            end
          end

          v
        end

        ## * +each+ must be called without arguments and only yield Strings.
        def each(*args)
          raise LintError, "rack.input#each called with arguments" unless args.size == 0
          @input.each { |line|
            unless line.kind_of? String
              raise LintError, "rack.input#each didn't yield a String"
            end
            yield line
          }
        end

        ## * +close+ must never be called on the input stream.
        def close(*args)
          raise LintError, "rack.input#close must not be called"
        end
      end

      ##
      ## === The Error Stream
      ##
      def check_error(error)
        ## The error stream must respond to +puts+, +write+ and +flush+.
        [:puts, :write, :flush].each { |method|
          unless error.respond_to? method
            raise LintError, "rack.error #{error} does not respond to ##{method}"
          end
        }
      end

      class ErrorWrapper
        def initialize(error)
          @error = error
        end

        ## * +puts+ must be called with a single argument that responds to +to_s+.
        def puts(str)
          @error.puts str
        end

        ## * +write+ must be called with a single argument that is a String.
        def write(str)
          raise LintError, "rack.errors#write not called with a String" unless str.kind_of? String
          @error.write str
        end

        ## * +flush+ must be called without arguments and must be called
        ##   in order to make the error appear for sure.
        def flush
          @error.flush
        end

        ## * +close+ must never be called on the error stream.
        def close(*args)
          raise LintError, "rack.errors#close must not be called"
        end
      end

      class HijackWrapper
        extend Forwardable

        REQUIRED_METHODS = [
          :read, :write, :read_nonblock, :write_nonblock, :flush, :close,
          :close_read, :close_write, :closed?
        ]

        def_delegators :@io, *REQUIRED_METHODS

        def initialize(io)
          @io = io
          REQUIRED_METHODS.each do |meth|
            raise LintError, "rack.hijack_io must respond to #{meth}" unless io.respond_to? meth
          end
        end
      end

      ##
      ## === Hijacking
      ##
      #
      # AUTHORS: n.b. The trailing whitespace between paragraphs is important and
      # should not be removed. The whitespace creates paragraphs in the RDoc
      # output.
      #
      ## ==== Request (before status)
      ##
      def check_hijack(env)
        if env[RACK_IS_HIJACK]
          ## If rack.hijack? is true then rack.hijack must respond to #call.
          original_hijack = env[RACK_HIJACK]
          raise LintError, "rack.hijack must respond to call" unless original_hijack.respond_to?(:call)
          env[RACK_HIJACK] = proc do
            ## rack.hijack must return the io that will also be assigned (or is
            ## already present, in rack.hijack_io.
            io = original_hijack.call
            HijackWrapper.new(io)
            ##
            ## rack.hijack_io must respond to:
            ## <tt>read, write, read_nonblock, write_nonblock, flush, close,
            ## close_read, close_write, closed?</tt>
            ##
            ## The semantics of these IO methods must be a best effort match to
            ## those of a normal ruby IO or Socket object, using standard
            ## arguments and raising standard exceptions. Servers are encouraged
            ## to simply pass on real IO objects, although it is recognized that
            ## this approach is not directly compatible with SPDY and HTTP 2.0.
            ##
            ## IO provided in rack.hijack_io should preference the
            ## IO::WaitReadable and IO::WaitWritable APIs wherever supported.
            ##
            ## There is a deliberate lack of full specification around
            ## rack.hijack_io, as semantics will change from server to server.
            ## Users are encouraged to utilize this API with a knowledge of their
            ## server choice, and servers may extend the functionality of
            ## hijack_io to provide additional features to users. The purpose of
            ## rack.hijack is for Rack to "get out of the way", as such, Rack only
            ## provides the minimum of specification and support.
            env[RACK_HIJACK_IO] = HijackWrapper.new(env[RACK_HIJACK_IO])
            io
          end
        else
          ##
          ## If rack.hijack? is false, then rack.hijack should not be set.
          raise LintError, "rack.hijack? is false, but rack.hijack is present" unless env[RACK_HIJACK].nil?
          ##
          ## If rack.hijack? is false, then rack.hijack_io should not be set.
          raise LintError, "rack.hijack? is false, but rack.hijack_io is present" unless env[RACK_HIJACK_IO].nil?
        end
      end

      ##
      ## ==== Response (after headers)
      ##
      ## It is also possible to hijack a response after the status and headers
      ## have been sent.
      def check_hijack_response(headers, env)
        ## In order to do this, an application may set the special header
        ## <tt>rack.hijack</tt> to an object that responds to <tt>call</tt>
        ## accepting an argument that conforms to the <tt>rack.hijack_io</tt>
        ## protocol.
        ##
        ## After the headers have been sent, and this hijack callback has been
        ## called, the application is now responsible for the remaining lifecycle
        ## of the IO. The application is also responsible for maintaining HTTP
        ## semantics. Of specific note, in almost all cases in the current SPEC,
        ## applications will have wanted to specify the header Connection:close in
        ## HTTP/1.1, and not Connection:keep-alive, as there is no protocol for
        ## returning hijacked sockets to the web server. For that purpose, use the
        ## body streaming API instead (progressively yielding strings via each).
        ##
        ## Servers must ignore the <tt>body</tt> part of the response tuple when
        ## the <tt>rack.hijack</tt> response API is in use.

        if env[RACK_IS_HIJACK] && headers[RACK_HIJACK]
          unless headers[RACK_HIJACK].respond_to? :call
            raise LintError, 'rack.hijack header must respond to #call'
          end
          original_hijack = headers[RACK_HIJACK]
          proc do |io|
            original_hijack.call HijackWrapper.new(io)
          end
        else
          ##
          ## The special response header <tt>rack.hijack</tt> must only be set
          ## if the request env has <tt>rack.hijack?</tt> <tt>true</tt>.
          unless headers[RACK_HIJACK].nil?
            raise LintError, 'rack.hijack header must not be present if server does not support hijacking'
          end

          nil
        end
      end
      ##
      ## ==== Conventions
      ##
      ## * Middleware should not use hijack unless it is handling the whole
      ##   response.
      ## * Middleware may wrap the IO object for the response pattern.
      ## * Middleware should not wrap the IO object for the request pattern. The
      ##   request pattern is intended to provide the hijacker with "raw tcp".
      ##

      ## == The Response
      ##
      ## === The Status
      ##
      def check_status(status)
        ## This is an HTTP status. It must be an Integer greater than or equal to
        ## 100.
        unless status.is_a?(Integer) && status >= 100
          raise LintError, "Status must be an Integer >=100"
        end
      end

      ##
      ## === The Headers
      ##
      def check_headers(headers)
        ## The headers must be a unfrozen Hash.
        unless headers.kind_of?(Hash)
          raise LintError, "headers object should be a hash, but isn't (got #{headers.class} as headers)"
        end
        
        if headers.frozen?
          raise LintError, "headers object should not be frozen, but is"
        end

        headers.each do |key, value|
          ## The header keys must be Strings.
          unless key.kind_of? String
            raise LintError, "header key must be a string, was #{key.class}"
          end

          ## Special headers starting "rack." are for communicating with the
          ## server, and must not be sent back to the client.
          next if key.start_with?("rack.")

          ## The header must not contain a +Status+ key.
          raise LintError, "header must not contain status" if key == "status"
          ## Header keys must conform to RFC7230 token specification, i.e. cannot
          ## contain non-printable ASCII, DQUOTE or "(),/:;<=>?@[\]{}".
          raise LintError, "invalid header name: #{key}" if key =~ /[\(\),\/:;<=>\?@\[\\\]{}[:cntrl:]]/
          ## Header keys must not contain uppercase ASCII characters (A-Z).
          raise LintError, "uppercase character in header name: #{key}" if key =~ /[A-Z]/

          ## Header values must be either a String instance,
          if value.kind_of?(String)
            check_header_value(key, value)
          elsif value.kind_of?(Array)
            ## or an Array of String instances,
            value.each{|value| check_header_value(key, value)}
          else
            raise LintError, "a header value must be a String or Array of Strings, but the value of '#{key}' is a #{value.class}"
          end
        end
      end

      def check_header_value(key, value)
        ## such that each String instance must not contain characters below 037.
        if value =~ /[\000-\037]/
          raise LintError, "invalid header value #{key}: #{value.inspect}"
        end
      end

      ##
      ## === The content-type
      ##
      def check_content_type(status, headers)
        headers.each { |key, value|
          ## There must not be a <tt>content-type</tt> header key when the +Status+ is 1xx,
          ## 204, or 304.
          if key == "content-type"
            if Rack::Utils::STATUS_WITH_NO_ENTITY_BODY.key? status.to_i
              raise LintError, "content-type header found in #{status} response, not allowed"
            end
            return
          end
        }
      end

      ##
      ## === The content-length
      ##
      def check_content_length(status, headers)
        headers.each { |key, value|
          if key == 'content-length'
            ## There must not be a <tt>content-length</tt> header key when the
            ## +Status+ is 1xx, 204, or 304.
            if Rack::Utils::STATUS_WITH_NO_ENTITY_BODY.key? status.to_i
              raise LintError, "content-length header found in #{status} response, not allowed"
            end
            @content_length = value
          end
        }
      end

      def verify_content_length(size)
        if @head_request
          unless size == 0
            raise LintError, "Response body was given for HEAD request, but should be empty"
          end
        elsif @content_length
          unless @content_length == size.to_s
            raise LintError, "content-length header was #{@content_length}, but should be #{size}"
          end
        end
      end

      ##
      ## === The Body
      ##
      ## The Body is typically an +Array+ of +String+ instances, an enumerable
      ## that yields +String+ instances, a +Proc+ instance, or a File-like
      ## object.
      ##
      ## The Body must respond to +each+ or +call+. It may optionally respond to
      ## +to_path+.
      ##
      ## A Body that responds to +each+ is considered to be an Enumerable Body.
      ##
      ## A Body that responds to +call+ is considered to be a Streaming Body.
      ##
      ## A Body that responds to +to_path+ is expected to generate the same
      ## content as would be produced by reading a local file opened with the
      ## path returned by calling +to_path+.
      ##
      ## A body that responds to both +each+ and +call+ must be treated as an
      ## Enumerable Body, not a Streaming Body. If it responds to +each+, you
      ## must call +each+ and not +call+. If the body doesn't respond to
      ## +each+, then you can assume it responds to +call+.

      ##
      ## ==== Enumerable Body
      ##
      def each
        ## The Enumerable Body must respond to +each+.
        raise LintError, "Enumerable Body must respond to each" unless @body.respond_to?(:each)

        ## It must only be called once.
        raise LintError, "Response body must only be invoked once (#{@invoked})" unless @invoked.nil?

        @invoked = :each

        @body.each do |chunk|
          ## and must only yield String values.
          unless chunk.kind_of? String
            raise LintError, "Body yielded non-string value #{chunk.inspect}"
          end

          ##
          ## The Body itself should not be an instance of String, as this will
          ## break in Ruby 1.9.
          ##
          ## Middleware must not call +each+ directly on the Body.
          ## Instead, middleware can return a new Body that calls +each+ on the
          ## original Body, yielding at least once per iteration.
          if @lint[0] == self
            @env['rack.lint.body_iteration'] += 1
          else
            if (@env['rack.lint.body_iteration'] -= 1) > 0
              raise LintError, "New body must yield at least once per iteration of old body"
            end
          end

          @size += chunk.bytesize
          yield chunk
        end

        verify_content_length(@size)

        verify_to_path
      end

      def respond_to?(sym, *)
        if sym.to_s == 'to_ary'
          @body.respond_to? sym
        else
          super
        end
      end

      ##
      ## If the Body responds to +to_ary+, it must return an Array whose
      ## contents are identical to that produced by calling +each+.
      ## Middleware may call +to_ary+ directly on the Body and return a new Body in its place.
      ## In other words, middleware can only process the Body directly if it responds to +to_ary+.
      def to_ary
        @body.to_ary.tap do |content|
          unless content == @body.enum_for.to_a
            raise LintError, "#to_ary not identical to contents produced by calling #each"
          end
        end
      ensure
        close
      end

      ##
      ## If the Body responds to +close+, it will be called after iteration. If
      ## the original Body is replaced by a new Body, the new Body
      ## must close the original Body after iteration, if it responds to +close+.
      ## If the Body responds to both +to_ary+ and +close+, its
      ## implementation of +to_ary+ must call +close+ after iteration.
      def close
        @closed = true
        @body.close if @body.respond_to?(:close)
        index = @lint.index(self)
        unless @env['rack.lint'][0..index].all? {|lint| lint.instance_variable_get(:@closed)}
          raise LintError, "Body has not been closed"
        end
      end

      def verify_to_path
        ##
        ## If the Body responds to +to_path+, it must return a String
        ## identifying the location of a file whose contents are identical
        ## to that produced by calling +each+; this may be used by the
        ## server as an alternative, possibly more efficient way to
        ## transport the response.
        if @body.respond_to?(:to_path)
          unless ::File.exist? @body.to_path
            raise LintError, "The file identified by body.to_path does not exist"
          end
        end

        ##
        ## The Body commonly is an Array of Strings, the application
        ## instance itself, or a File-like object.
      end

      ##
      ## ==== Streaming Body
      ##
      def call(stream)
        ## The Streaming Body must respond to +call+.
        raise LintError, "Streaming Body must respond to call" unless @body.respond_to?(:call)

        ## It must only be called once.
        raise LintError, "Response body must only be invoked once (#{@invoked})" unless @invoked.nil?

        @invoked = :call

        ## It takes a +stream+ argument.
        ##
        ## The +stream+ argument must implement:
        ## <tt>read, write, flush, close, close_read, close_write, closed?</tt>
        ##
        @body.call(StreamWrapper.new(stream))
      end

      class StreamWrapper
        extend Forwardable

        ## The semantics of these IO methods must be a best effort match to
        ## those of a normal Ruby IO or Socket object, using standard arguments
        ## and raising standard exceptions. Servers are encouraged to simply
        ## pass on real IO objects, although it is recognized that this approach
        ## is not directly compatible with HTTP/2.
        REQUIRED_METHODS = [
          :read, :write, :flush, :close,
          :close_read, :close_write, :closed?
        ]

        def_delegators :@stream, *REQUIRED_METHODS

        def initialize(stream)
          @stream = stream
          
          REQUIRED_METHODS.each do |method_name|
            raise LintError, "Stream must respond to #{method_name}" unless stream.respond_to?(method_name)
          end
        end
      end

      # :startdoc:
    end
  end
end

##
## == Thanks
## Some parts of this specification are adopted from {PEP 333 – Python Web Server Gateway Interface v1.0}[https://peps.python.org/pep-0333/]
## I'd like to thank everyone involved in that effort.
