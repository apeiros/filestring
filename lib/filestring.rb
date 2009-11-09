#fs = FileString.new("../data/helloworld.txt")

# SYNOPSIS
#   fs = FileString.with_default("some_file.txt", "hello world!")
#   fs[6,5]                    # => "world"
#   fs[6,5] = "dude"           # => "dude"
#   fs.upcase!
#   fs.to_s                    # => "HELLO DUDE!"
#   File.read("some_file.txt") # => "HELLO DUDE!"
#
# DESCRIPTION
# Replicates all (or most) of String's methods, therefore look
# in String for documentation of the methods.
# All in-place operations of String (like gsub!, []= etc.) will
# directly and immediatly affect the file the FileString is tied to.
# Methods that are not in-place and return a String in String's
# methods will return a String here too.
# A non-existing file is treated as an empty string - if you add content
# to the string, it'll create the file.
#
# A NOTE REGARDING WINDOWS (BINARY MODE)
# All operations are performed reading/writing the file in binary mode.
#
# PERFORMANCE
# Performance was not a main concern when writing FileString.
# However, certain methods contain some optimizations wrt Files
# being potentially slow and possibly big. Instead of working on
# the whole file, they'll work on chunks and shortcut if possible.
# E.g. FileString#== will only compare the first BlockSize bytes
# if they differ in the first BlockSize bytes. FileString#[]= will
# only rewrite as little as necessary.
#
# COMPARISON WITH STRINGS
# A FileString is == and eql? to a String with the same content as
# the file it is linked to.
#
# IMPORTANT
# FileString does no kind of locking on the file - if you need that,
# you have to do it yourself.
#
# TODO
# * call to_str on some args in some methods (investigate in which)
#   in case the arg is another FileString
# * reimplement some of the twin/twin! methods to use chunks - might
#   do a switch depending on the filesize (e.g. >8MB -> use chunks)
class FileString

  # Returns the path of the file this FileString is linked to.
  # The path is expanded (using File::expand_path)
  attr_reader :path

  # Will always create a file with to_string as content, even if
  # it has to delete a previously existing file in order to.
  # If to_string is nil, it's just like a plain FileString::new.
  def self.force(path, to_string=nil)
    file_string = new(path)
    file_string.replace(to_string)
    file_string
  end

  # If the file this FileString instance will link to doesn't exist,
  # this method will create it and set its content to default_string.
  # If default_string is nil, it's just like a plain FileString::new.
  def self.with_default(path, default_string=nil)
    file_string = new(path)
    file_string.replace(default_string) if default_string && !file_string.exist?
    file_string
  end

  # The argument is the path to the file this FileString shall be
  # linked to. The path is expanded (using File::expand_path).
  # The file must not exist at initialization of FileString, not
  # even between separate operations on it. Only at the time you
  # perform operations on it, its presence is required.
  def initialize(path)
    @path   = File.expand_path(path)
  end

  # BlockSize (or a multiple of it) is used as chunksize for operations
  # working on chunks
  BlockSize = 4096

  # 1.9 doesn't include Enumerable in String, 1.8 does - emulate
  include Enumerable if String.include?(Enumerable)
  include Comparable

  # FileString specific method - tests whether the file this FileString
  # is linked against exists.
  def exist?
    File.exist?(@path)
  end

  # FileString specific method - removes the file this FileString
  # is linked against. FileStrings with inexistent linked file behave
  # like an empty string.
  # Returns whether a file was actually deleted.
  def delete_file
    File.delete(@path)
    true
  rescue Errno::ENOENT # testing for existence would be a race condition
    false
  end

  # :stopdoc:

  # We need this class to avoid getting "IOError, closed stream" on
  # methods that return an Enumerator operating on the open IO.
  # e.g. FileString#lines without a block.
  class Enumerator
    include Enumerable

    def initialize(file_string, meth)
      @file_string = file_string
      @meth        = meth
    end

    def each(&block)
      @file_string.__send__(:_open) { |fh|
        fh.__send__(@meth).each(&block)
      }
    end

    def each_with_index(&block)
      @file_string.__send__(:_open) { |fh|
        fh.__send__(@meth).each_with_index(&block)
      }
    end
  end

  def <=>(other)
    a,b,off = nil

    if other.class == FileString then
      _open do |fh_a|
        File.open(other.path, "rb") do |fh_b|
          a = fh_a.read(BlockSize)
          b = fh_b.read(BlockSize)
          while a && b
            cmp = a <=> b
            return cmp unless cmp.zero?
            a = fh_a.read(BlockSize)
            b = fh_b.read(BlockSize)
          end
        end
      end
    else
      other = other.to_str
      _open do |fh|
        off = 0
        b   = other[off,BlockSize]
        a   = fh.read(BlockSize)
        while a && b
          cmp = a <=> b
          return cmp unless cmp.zero?
          off += BlockSize
          b    = other[off,BlockSize]
          a    = fh.read(BlockSize)
        end
      end
    end

    # check which one is shorter
    if a.nil? then
      if b.nil? then # both have the same length
        return 0
      else # a is shorter
        return -1
      end
    else # b is shorter
      return 1
    end
  end

  alias === ==
  alias eql? ==

  def length(cached=false)
    File.size(@path)
  rescue Errno::ENOENT # testing for existence would be a race condition
    0
  end
  alias size length
  alias bytesize length

  def [](off, len=nil)
    file_size = length
    off, len  = *_normalize_index(file_size, off, len)

    if off > file_size then
      nil
    elsif off == file_size then
      ""
    else
      _open { |fh|
        fh.seek(off)
        fh.read(len)
      }
    end
  end

  def []=(*args)
    unless args.size.between?(2,3) then
      raise ArgumentError, "wrong number of arguments (#{args.size} for 2..3)"
    end

    file_size = length
    data      = args.pop
    off, len  = _normalize_index(file_size, *args)

    if off > file_size then
      raise IndexError, "index #{off} out of file"
    elsif data.length == len then
      _open("r+b") { |fh|
        fh.seek(off)
        fh.write(data)
      }
    else
      _open("r+b") { |fh|
        fh.seek(off+len)
        rest = fh.read
        fh.seek(off)
        fh.write(data)
        fh.write(rest)
        fh.truncate(file_size-len+data.length) if data.length < len
      }
    end

    self
  end

  def insert(index, other_str)
    self[index,0] = other_str
    self
  end

  def concat(obj)
    obj = obj.chr if Fixnum === obj
    _open "ab" do |fh| fh.write(obj) end
    self
  end
  alias << concat

  def count(*args)
    sum = 0
    _open do |fh|
      buffer = fh.read(BlockSize)
      sum   += buffer.count(*args)
    end

    sum
  end

  def empty?
    length.zero?
  end

  def include?(obj)
    obj = obj.chr if Fixnum === obj

    # calculate reading size
    q,r       = *obj.size.divmod(BlockSize)
    q        += 1 if r > 0
    read_size = BlockSize*q

    # find in whole file if file < read_size
    if length <= read_size
      _read.include?(obj)

    # find in chunks
    else
      _open { |fh|
        buffer = fh.read(read_size)
        append = fh.read(read_size)
        begin
          buffer = buffer[-read_size,read_size]+append
          return true if buffer.include?(obj)
        end while append = fh.read(read_size)
      }

      false
    end
  end

  def index(obj, offset=nil)
    # special cases
    return nil if offset && offset > length
    return offset if obj == ""

    _open { |fh|
      fh.seek(offset) if offset
      offset ||= 0
      found    = nil

      if Regexp === obj # can't handle regexen with chunks
        found = fh.read.index(obj)
      else
        obj = obj.chr if Fixnum === obj

        # calculate reading size
        q,r       = *obj.size.divmod(BlockSize)
        q        += 1 if r > 0
        read_size = BlockSize*q

        # find in whole file if file < read_size
        if length-offset <= read_size
          fh.read.index(obj)

        # find in chunks
        else
          buffer = fh.read(read_size)
          append = fh.read(read_size)
          begin
            buffer = buffer[-read_size,read_size]+append
            found  = buffer.index(obj)
            offset = fh.pos - 2*read_size
          end while found.nil? && append = fh.read(read_size)
        end        
      end
          
      found ? found + offset : found
    }
  end

  def rindex(obj, upperbound=nil)
    # special cases
    return length if obj == ""

    offset = 0
    _open { |fh|
      upperbound ||= length
      found        = nil

      if Regexp === obj # can't handle regexen with chunks
        found = fh.read(upperbound).rindex(obj)
      else
        obj = obj.chr if Fixnum === obj

        # calculate reading size
        q,r       = *obj.size.divmod(BlockSize)
        q        += 1 if r > 0
        read_size = BlockSize*q

        # find in whole file if upperbound <= read_size*2
        if upperbound <= read_size*2
          found = fh.read(upperbound).rindex(obj)

        # find in chunks
        else
          fh.seek(-read_size*2, IO::SEEK_END)
          prepend = fh.read(read_size)
          buffer  = fh.read(read_size)
          begin
            buffer = prepend+buffer[0,read_size]
            found  = buffer.rindex(obj)
            offset = fh.pos - 2*read_size
          end while found.nil? && append = fh.read(read_size)
        end
      end

      found ? found + offset : found
    }
  end

  def replace(str)
    _write(str)
    self
  end

  def start_with?(*strings)
    return false if empty?

    _open { |fh|
      buffer = fh.read(strings.first.size)
      strings.any? { |string|
        if string.size < buffer.size
          buffer.start_with?(string)
        elsif string[0,buffer.size] == buffer then
          buffer << fh.read(string.size-buffer.size)
          string == buffer
        else
          false
        end
      }
    }
  end

  def end_with?(*strings)
    return false if empty?

    _open { |fh|
      buffer_size = strings.first.size
      fh.seek(-buffer_size, IO::SEEK_END)
      buffer = fh.read(buffer_size)
      strings.any? { |string|
        if string.size < buffer.size
          buffer.end_with?(string)
        elsif string[-buffer.size,buffer.size] == buffer then
          fh.seek(-string.size, IO::SEEK_END)
          buffer[0,0] = fh.read(string.size-buffer.size)
          string == buffer
        else
          false
        end
      }
    }
  end


  # Methods that have in-place and returning variants
  # Only in-place methods that return nil if there's no change and self
  # otherwise
  %w[
    capitalize
    chomp
    chop
    delete
    downcase
    gsub
    lstrip
    next
    reverse
    rstrip
    slice
    squeeze
    strip
    sub
    succ
    swapcase
    tr
    tr_s
    upcase
  ].each do |method_name|
    class_eval <<-END_OF_METHODS
      def #{method_name}(*args, &block)
        _read.#{method_name}(*args)
      end
    
      def #{method_name}!(*args, &block)
        data = _read
        rv   = data.#{method_name}!(*args, &block)
        _write(data)
        rv && self
      end
    END_OF_METHODS
  end

  # Methods that require reading the file and applying String's implementation
  # of the method on the result of it
  %w[
    %
    *
    +
    =~
    casecmp
    center
    crypt
    hash
    hex
    ljust
    match
    oct
    partition
    rjust
    rpartition
    scan
    split
    unpack
    upto
    to_i
    to_f
    to_sym
  ].each do |method_name|
    class_eval <<-END_OF_METHODS
      def #{method_name}(*args, &block)
        _read.#{method_name}(*args, &block)
      end
    END_OF_METHODS
  end
  
  # Methods called directly on the read-open filehandle
  %w[
    bytes
    chars
    each
    each_byte
    each_char
    each_line
    lines
  ].each do |method_name|
    class_eval <<-END_OF_METHODS
      def #{method_name}(*args, &block)
        if block then
          _open do |fh|
            fh.#{method_name}(*args, &block)
          end
        else
          Enumerator.new(self, :#{method_name})
        end
      end
    END_OF_METHODS
  end



  alias intern to_sym

  def to_s
    File.read(@path)
  end
  alias to_str to_s

  def inspect
    sprintf "#<%s %p>", self.class.name, @path
  end

private
  def _open(mode="rb", &block)
    File.open(@path, mode, &block)
  end

  def _read
    File.read(@path)
  rescue Errno::ENOENT # testing for existence would be a race condition
    ""
  end

  def _write(data)
    _open "wb" do |fh|
      fh.write(data)
    end
  end

  def _normalize_index(file_size, off, len=nil)
    off = length+off if Integer === off && off < 0
    if len.nil? then
      if Range === off then
        range  = off
        off    = range.begin < 0 ? length + range.begin : range.begin
        endoff = range.end   < 0 ? length + range.end+1 : range.end
        len    = endoff-off
      else
        len    = length-off
      end
    end

    return off, len
  end

  # :startdoc:
end
