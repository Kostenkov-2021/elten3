# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

require "fileutils"

module Programs
  class << self
    def install_package(file, preferred_program: nil, installation_source: nil, info: nil)
      if EltenAppPackage.package?(file)
        package = EltenAppPackage.new(file)
        existing = installed_entry_for_install_manifest(package.manifest)
        destination = eltenapp_install_path(file, package.manifest, existing, preferred_program)
        install_eltenapp_package(file, destination, existing, installation_source: installation_source)
      else
        info ||= setup_package_info(file)
        existing = installed_entry_for_install_manifest(info[:manifest])
        destination = install_destination_for_info(file, info, existing, preferred_program)
        install_setup_package(file, destination, existing, info, installation_source: installation_source)
      end
    end

    def remote_package_filename(program)
      value = program.respond_to?(:original_filename) ? program.original_filename.to_s : ""
      value = program.path.to_s if value == "" && program.respond_to?(:path)
      safe_install_base(value) + ".eltsetup"
    end

    private

    def extract_setup_package(zip, destination)
      zip_entries(zip).each do |entry|
        name = safe_zip_entry_name(entry)
        next if name == "__manifest.json"
        target = EltenPath.join(destination, name)
        if zip_directory_entry?(entry)
          FileUtils.mkdir_p(target)
        else
          zip_extract(entry, target)
        end
      end
    end

    def install_setup_package(file, destination, existing_entry = nil, info = nil, installation_source: nil)
      info ||= setup_package_info(file)
      if info[:single_file]
        return install_setup_single_file_package(file, destination, existing_entry, info,
          installation_source: installation_source)
      end
      staging = unique_install_path("staging")
      backups = []
      replaced = false
      begin
        ensure_install_path!(destination)
        FileUtils.mkdir_p(staging)
        open_zip(file) { |zip| extract_setup_package(zip, staging) }
        discover_folder_source(File.basename(destination), staging)
        replace_destination_with_staging(staging, destination, existing_entry, backups)
        replaced = true
        entry = EltenPath.relative_from(destination, Dirs.apps)
        activate_installed_entry(entry, existing_entry, destination, backups,
          installation_source: installation_source)
      rescue Exception => error
        Log.warning("Program setup installation failed: #{error.class}: #{error.message}")
        rollback_install(destination, backups, existing_entry, replaced)
        raise
      ensure
        remove_install_path(staging)
      end
    end

    def install_setup_single_file_package(file, destination, existing_entry, info, installation_source: nil)
      staging = unique_install_path("staging") + ".eltenapp"
      begin
        open_zip(file) do |zip|
          entry = zip_entries(zip).find { |zip_entry| normalize_entry_name(zip_entry.name) == info[:entry] }
          raise ProgramError, "Missing setup eltenapp payload" if entry == nil
          zip_extract(entry, staging)
        end
        install_eltenapp_package(staging, destination, existing_entry,
          installation_source: installation_source)
      rescue Exception => error
        Log.warning("Program single-file setup installation failed: #{error.class}: #{error.message}")
        raise
      ensure
        remove_install_path(staging)
      end
    end

    def install_eltenapp_package(file, destination, existing_entry = nil, installation_source: nil)
      backups = []
      replaced = false
      begin
        ensure_install_path!(destination)
        EltenAppPackage.new(file)
        backup_install_path(destination, backups)
        backup_existing_entry(existing_entry, destination, backups)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.mv(file, destination)
        replaced = true
        entry = EltenPath.relative_from(destination, Dirs.apps)
        activate_installed_entry(entry, existing_entry, destination, backups,
          installation_source: installation_source)
      rescue Exception => error
        Log.warning("Program eltenapp installation failed: #{error.class}: #{error.message}")
        rollback_install(destination, backups, existing_entry, replaced)
        raise
      end
    end

    def replace_destination_with_staging(staging, destination, existing_entry, backups)
      ensure_install_path!(staging)
      ensure_install_path!(destination)
      backup_install_path(destination, backups)
      backup_existing_entry(existing_entry, destination, backups)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.mv(staging, destination)
    end

    def activate_installed_entry(entry, existing_entry, _destination, backups, installation_source: nil)
      delete(existing_entry, :reason => :reload) if existing_entry != nil
      delete(entry, :reason => :reload) if existing_entry == nil || existing_entry != entry
      load_sig(entry, installation_source: installation_source, raise_errors: true)
      cleanup_install_backups(backups)
      entry
    end

    def rollback_install(destination, backups, existing_entry = nil, replaced = false)
      remove_install_path(destination) if replaced
      backups.reverse_each do |original, backup|
        next if !File.exist?(backup)
        ensure_install_path!(original)
        ensure_install_path!(backup)
        FileUtils.mkdir_p(File.dirname(original))
        remove_install_path(original)
        FileUtils.mv(backup, original)
      end
      load_sig(existing_entry) if existing_entry != nil && File.exist?(EltenPath.join(Dirs.apps, existing_entry))
    rescue Exception => error
      Log.warning("Program installation rollback failed: #{error.class}: #{error.message}")
    end

    def backup_existing_entry(existing_entry, destination, backups)
      return if existing_entry == nil || existing_entry == ""
      existing_path = EltenPath.join(Dirs.apps, existing_entry)
      return if same_install_path?(existing_path, destination)
      backup_install_path(existing_path, backups)
    end

    def backup_install_path(path, backups)
      return if path == nil || path == "" || !File.exist?(path)
      ensure_install_path!(path)
      backup = unique_install_path("backup")
      FileUtils.mv(path, backup)
      backups.push([path, backup])
    end

    def cleanup_install_backups(backups)
      backups.each { |_original, backup| remove_install_path(backup) }
    end

    def remove_install_path(path)
      return if path == nil || path == "" || !File.exist?(path)
      ensure_install_path!(path)
      FileUtils.rm_rf(path)
    rescue Exception => error
      Log.warning("Program install path cleanup failed for #{path}: #{error.class}: #{error.message}")
    end

    def ensure_install_path!(path)
      root_path = File.expand_path(Dirs.apps.to_s).tr("\\", "/")
      target_path = File.expand_path(path.to_s).tr("\\", "/")
      if RUBY_PLATFORM =~ /mswin|mingw/i
        root_path = root_path.downcase
        target_path = target_path.downcase
      end
      if target_path == root_path || !target_path.start_with?(root_path + "/")
        raise ProgramError, "Invalid program installation path #{path}"
      end
      true
    end

    def unique_install_path(prefix)
      base = EltenPath.join(Dirs.apps, ".#{prefix}-#{Time.now.to_i}-#{rand(36**6).to_s(36)}")
      path = base
      index = 0
      while File.exist?(path)
        index += 1
        path = "#{base}-#{index}"
      end
      path
    end

    def same_install_path?(first, second)
      left = File.expand_path(first.to_s).tr("\\", "/")
      right = File.expand_path(second.to_s).tr("\\", "/")
      if RUBY_PLATFORM =~ /mswin|mingw/i
        left = left.downcase
        right = right.downcase
      end
      left == right
    rescue Exception
      first.to_s == second.to_s
    end

    def installed_entry_for_install_manifest(manifest)
      installed = installed_entry_for_id(manifest.id)
      installed == nil ? nil : installed.realpath
    end

    def install_destination_for_info(file, info, existing_entry = nil, preferred_program = nil)
      if info[:single_file]
        eltenapp_install_path(file, info[:manifest], existing_entry, preferred_program, info[:entry])
      else
        folder_install_path(file, info[:payload], existing_entry, preferred_program, info[:entry], info[:manifest])
      end
    end

    def eltenapp_install_path(file, manifest, existing_entry = nil, preferred_program = nil, entry_name = nil)
      base = safe_install_base(entry_name)
      base = preferred_program_install_base(preferred_program) if base == "program" && preferred_program != nil
      base = safe_install_base(manifest.name) if base == "program" && manifest != nil
      base = safe_install_base(File.basename(file, File.extname(file))) if base == "program"
      available_install_path(EltenPath.join(Dirs.apps, base + ".eltenapp"), existing_entry,
        manifest == nil ? "" : manifest.id)
    end

    def folder_install_path(file, payload, existing_entry = nil, preferred_program = nil, entry_name = nil, manifest = nil)
      base = safe_install_base(payload["path"]) if payload.is_a?(Hash)
      base = preferred_program_install_base(preferred_program) if (base == nil || base == "program") && preferred_program != nil
      base = safe_install_base(File.basename(entry_name.to_s, File.extname(entry_name.to_s))) if (base == nil || base == "program") && entry_name != nil
      base = safe_install_base(File.basename(file, File.extname(file))) if base == nil || base == "program"
      available_install_path(EltenPath.join(Dirs.apps, base), existing_entry,
        manifest == nil ? "" : manifest.id)
    end

    def preferred_program_install_base(program)
      return "program" if program == nil
      value = program.respond_to?(:original_filename) ? program.original_filename.to_s : ""
      value = program.path.to_s if value == "" && program.respond_to?(:path)
      safe_install_base(value)
    end

    def safe_install_base(value)
      base = normalize_entry_name(value.to_s)
      base = value.to_s if base == nil
      base = File.basename(base)
      extension = File.extname(base).downcase
      base = File.basename(base, File.extname(base)) if extension == ".eltenapp" || extension == ".eltsetup"
      base = base.gsub(/[\\\/:*?"<>|]/, "_").strip
      base = "program" if base == "" || base == "." || base == ".."
      base
    end

    def available_install_path(desired, existing_entry = nil, desired_uuid = "")
      ensure_install_path!(desired)
      existing_path = existing_entry == nil ? nil : EltenPath.join(Dirs.apps, existing_entry)
      return desired if existing_path != nil && same_install_path?(desired, existing_path)
      return desired if !File.exist?(desired) && !registry_path_conflict?(desired, desired_uuid)
      extension = File.extname(desired)
      base = extension == "" ? desired : desired[0...-extension.length]
      index = 1
      loop do
        candidate = extension == "" ? "#{base}(#{index})" : "#{base}(#{index})#{extension}"
        if (!File.exist?(candidate) && !registry_path_conflict?(candidate, desired_uuid)) ||
            (existing_path != nil && same_install_path?(candidate, existing_path))
          return candidate
        end
        index += 1
      end
    end

    def registry_path_conflict?(path, desired_uuid)
      desired_uuid = desired_uuid.to_s.downcase
      return false if desired_uuid == ""
      entry = EltenPath.relative_from(path, Dirs.apps)
      storage_id = entry_storage_id(entry)
      registered_uuid = registry_uuid_for_storage_id(storage_id).to_s.downcase
      registered_uuid != "" && registered_uuid != desired_uuid
    rescue Exception
      false
    end
  end
end
