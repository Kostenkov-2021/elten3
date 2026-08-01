# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.

module EltenAPI
  module Controls
    private
     class Tree < FormField
       attr_reader :sel
       attr_accessor :options
       attr_accessor :index
       attr_accessor :options
       attr_reader :opfocused
       def initialize(options, data: 0, header: "", quiet: true, left_right: false, silent: false)
                index=0
         @options=options
         @header=header
         @silent=silent
         @lr=left_right
         @way=[]
@sel=createselect([],0,true)
focus if quiet==false
end
def update
super
  @opfocused=false
        if @sel.selected? or @sel.expanded?
    o=@options.deep_dup
    for l in @way
      o=o[l][1..o[l].size-1]
    end
        if o[@sel.index].is_a?(Array)
            @way.push(@sel.index)
            @sel=createselect(@way)
            return
                  elsif key_pressed?(:key_enter)
          @opfocused=true
          end
    end
              if @way.size>0 and (@lr!=2 and @sel.collapsed?) or (key_pressed?(:key_up) and !navigation_modifier_held? and sel.index==0)
      ind=@way.last
      @way.delete_at(@way.size-1)
      @sel=createselect(@way,ind)
      return
    end
    @sel.update
  @index=getwayindex(@way+[@sel.index])-1
    end
       def createselect(way=[],selindex=0,quiet=false)
         opt=getelements(way)
         lr=@lr
         if lr==2
           if way.size==0
             lr=true
           else
             lr=false
             end
           end
           flags=0
           flags||=ListBox::Flags::LeftRight if lr
           flags||=ListBox::Flags::Silent if @silent
                    s=ListBox.new(opt, header: @header, index: selindex, flags: flags)
         speak(s.options[s.index], pan: s.lpos) if quiet!=true
                  return s
         end
         def searchway(way=[],tway=[],index=0)
                                 return [index,tway] if way==tway
           t=@options.deep_dup
                      for l in tway
             t=(t[l]==nil)?nil:(t[l][1..t[l].size-1])
           end
           return [index,tway] if t.is_a?(Array)==false
                                 for i in 0..t.size-1
                          x=searchway(way,tway+[i],index+1)
               if x[1]==way
                                 return x
                                 break
               else
                 index=x[0]
                 end
                                         end
           return [index,tway]
         end
         def getwayindex(index)
                      return searchway(index)[0]
                                 end
         def getelements(way=[])
sou=@options.deep_dup
         for l in way
           sou=sou[l][1..sou[l].size-1]
                end
              ret=sou
for i in 0..ret.size-1
  while ret[i].is_a?(Array)
    ret[i]=ret[i][0]
    end
  end
return ret
         end
         def focus(index=nil,count=nil)
@sel.focus(index, count)
         end
       end


     # Opens a file selection window and returns a path to file selected by user
     #
     # @param header [String] a window caption
     # @param path [String] an initial path
     # @param save [Boolean] hides a files, presents only directories
     # @param file [String] a file to focus
     # @return [String] an absolute path to a selected file or directory
     def get_file(header="", path: "", save: false, extensions: nil)
              dialog_open
       loop_update
       ft=FilesTree.new(header, path: path, hide_files: save, quiet: true, extensions: extensions)
                     ft.focus
       loop do
         loop_update
         ft.update
         if key_pressed?(:key_escape)
           dialog_close
           loop_update
           return nil
           break
         end
         if key_pressed?(:key_enter)
           dialog_close
           f=EltenPath.join(ft.path, ft.file)
           f=f[0...-1] if f.end_with?("/")
           if save == false and File.file?(ft.selected(true))
             loop_update
             return f
           break
         end
         if save == true
           if File.directory?(f)
             loop_update
                          return f
             break
           else
             f=EltenPath.dirname(f)
             loop_update
             return f
             break
             end
           end
         end
         if key_pressed?(:key_space)
           pt=ft.path
           ftp=input_text(p_("EAPI_Form", "Choose a path"), text: ft.path, escapable: true)
           ft.path=ftp if ftp!=nil and File.directory?(ftp)
         end
       end
              rescue Exception
         return nil
                  end


  end
end
