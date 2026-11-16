#!/usr/bin/ruby
# Calls the App Store Connect API and prints the JSON it returns.
#
#   scripts/asc.rb GET '/v1/bundleIds?filter[identifier]=dev.gooey.wheel'
#   scripts/asc.rb POST /v1/profiles body.json
#
# The key comes from GOOEY_ASC_KEY_ID, GOOEY_ASC_ISSUER_ID and GOOEY_ASC_KEY (the .p8 path), or
# from ~/.appstoreconnect/gooey.env, which sets the same names. The key has to be a Team key with
# Admin access to create certificates.
require "json"
require "net/http"
require "openssl"
require "base64"

env_file = File.expand_path("~/.appstoreconnect/gooey.env")
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    next unless line.chomp =~ /\A\s*(GOOEY_ASC_\w+)=(.*)\z/
    ENV[$1] ||= $2.strip.sub("$HOME", Dir.home)
  end
end
key_id, issuer, key_path = ENV.values_at("GOOEY_ASC_KEY_ID", "GOOEY_ASC_ISSUER_ID", "GOOEY_ASC_KEY")
abort "Set GOOEY_ASC_KEY_ID, GOOEY_ASC_ISSUER_ID and GOOEY_ASC_KEY." unless key_id && issuer && key_path
key_path = File.expand_path(key_path)
method, path, body_file = ARGV
abort "usage: asc.rb GET|POST|PATCH|DELETE <path> [body.json]" unless method && path

def b64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

key = OpenSSL::PKey::EC.new(File.read(key_path))
now = Time.now.to_i
signing_input = [
  b64url({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json),
  b64url({ iss: issuer, iat: now, exp: now + 15 * 60, aud: "appstoreconnect-v1" }.to_json),
].join(".")
# JWT wants the raw 64-byte r||s signature, not OpenSSL's DER encoding.
der = OpenSSL::ASN1.decode(key.sign("SHA256", signing_input))
signature = der.value.map { |n| n.value.to_s(2).rjust(32, "\0") }.join
token = "#{signing_input}.#{b64url(signature)}"

uri = URI(path.start_with?("http") ? path : "https://api.appstoreconnect.apple.com#{path}")
request = Net::HTTP.const_get(method.capitalize).new(uri)
request["Authorization"] = "Bearer #{token}"
if body_file
  request["Content-Type"] = "application/json"
  request.body = body_file == "-" ? $stdin.read : File.read(body_file)
end
response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |http| http.request(request) }
puts response.body unless response.body.to_s.empty?
exit(response.is_a?(Net::HTTPSuccess) ? 0 : 1)
