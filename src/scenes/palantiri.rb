# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

class Scene_Palantiri
  def main
    @table = TableBox.new(
      [p_("Palantiri", "Node"), p_("Palantiri", "Status")],
      nodes,
      header: p_("Palantiri", "Node connectivity test"),
      quiet: false
    )
    loop do
      loop_update
      @table.update
      $scene = Scene_Main.new if key_pressed?(:key_escape)
      break if $scene != self
    end
  end

  private

  def nodes
    [
      ["Annúminas", p_("Palantiri", "lost")],
      ["Amon Sûl", p_("Palantiri", "lost")],
      ["Elostirion", p_("Palantiri", "routing only to the West")],
      ["Osgiliath", p_("Palantiri", "master - lost")],
      ["Minas Anor", p_("Palantiri", "operational")],
      ["Minas Ithil", p_("Palantiri", "compromised")],
      ["Orthanc", p_("Palantiri", "operational")]
    ]
  end
end
