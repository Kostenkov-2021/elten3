# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.

require "openssl"

module EltenAPI
  module TLS
    class Error < StandardError
    end

    class << self
      def certificate_store
        @certificate_store || install!
      end

      def client_context
        context = OpenSSL::SSL::SSLContext.new
        context.set_params(
          verify_mode: OpenSSL::SSL::VERIFY_PEER,
          verify_hostname: true,
          cert_store: certificate_store
        )
        context
      end

      def install!
        return @certificate_store if @certificate_store != nil

        pem = EltenAPI::Resources.read("ssl/cert.pem").to_s.b
        if pem == ""
          raise Error, "Embedded TLS CA bundle is unavailable" if defined?(::EltenEmbedded)
          Log.warning("Embedded TLS CA bundle is unavailable; using OpenSSL defaults") if defined?(Log)
          return @certificate_store = OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE
        end

        certificates = OpenSSL::X509::Certificate.load(pem)
        raise Error, "Embedded TLS CA bundle contains no certificates" if certificates.empty?

        store = OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE
        added = 0
        certificates.each do |certificate|
          begin
            store.add_cert(certificate)
            added += 1
          rescue OpenSSL::X509::StoreError => e
            raise if e.message !~ /already in hash table/i
          end
        end
        Log.info("Embedded TLS certificate store installed: #{certificates.size} CAs, #{added} added") if defined?(Log)
        @certificate_store = store
      rescue ArgumentError, OpenSSL::OpenSSLError => e
        raise Error, "Cannot install embedded TLS CA bundle: #{e.message}"
      end
    end
  end
end

EltenAPI::TLS.install!
