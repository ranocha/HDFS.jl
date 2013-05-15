module HDFS

import  Base.show, Base.print_matrix,
        Base.size, Base.strides, Base.stride,
        Base.similar,
        Base.getindex, Base.setindex!,
        Base.push!, Base.pop!, Base.shift!, Base.empty!,
        Base.search, Base.beginswith,
        Base.start, Base.done, Base.next,
        Base.wait

abstract MapInputReader 
abstract MapInputIterator

export  hdfs_connect, hdfs_connect_as_user,
        hdfs_exists, hdfs_delete, 
        hdfs_flush, hdfs_get_capacity, hdfs_get_default_block_size, hdfs_get_path_info, hdfs_get_used, 
        hdfs_set_working_directory, hdfs_get_working_directory, hdfs_list_directory, hdfs_available,
        hdfs_create_directory, hdfs_rename, hdfs_close_file,
        hdfs_open_file, hdfs_open_file_read, hdfs_open_file_write, hdfs_open_file_append,
        hdfs_copy, hdfs_move,
        hdfs_pread, hdfs_read, hdfs_seek, hdfs_tell, hdfs_write,
        hdfs_set_replication,
        hdfs_get_hosts,
        # from hdfs_types.jl
        HDFS_OBJ_FILE, HDFS_OBJ_DIR, HDFS_OBJ_INVALID,
        HdfsFS, HdfsFile, HdfsFileInfo, HdfsFileInfoList,
        # from hdfs_jobs.jl
        results, status, mapreduce, unload, wait, times,
        HdfsJobCtx, HdfsJobRunInfo, HdfsJobSchedInfo,
        JobId,
        # from hdfs_reader.jl
        HdfsReader, HdfsReaderIter, 
        MapResultReader, MapResultReaderIter,
        iterator, start, done, next, 
        # from hdfs_mrutils.jl
        hdfs_find_rec_csv, mr_result_find_rec

using ChainedVectors
using URLParse

include("hdfs_types.jl")
include("hdfs_reader.jl")
include("map_result_reader.jl")
include("hdfs_jobs.jl")
include("hdfs_mrutils.jl")

const hdfs_fsstore = Dict{(String, Integer, String), Vector{Any}}()

finalize_file_info_list(fi::HdfsFileInfoList) = ccall((:hdfsFreeFileInfo, _libhdfs), Void, (Ptr{Void}, Int32), fi.c_info_ptr, length(fi.arr))
finalize_file_info(fi::HdfsFileInfo) = ccall((:hdfsFreeFileInfo, _libhdfs), Void, (Ptr{Void}, Int32), fi.c_info_ptr, 1)
function finalize_hdfs_fs(fs::HdfsFS) 
    (C_NULL == fs.ptr) && return
    key, arr = _get_ptr_ref(fs.host, fs.port, fs.user, false)
    if((arr[1] -= 1) == 0)
        ccall((:hdfsDisconnect, _libhdfs), Int32, (Ptr{Void},), fs.ptr) 
        arr[2] = fs.ptr = C_NULL
        # TODO: remove from hdfs_fsstore to save space
    end
end

# hdfs_connect returns pointers to the same handle across multiple calls for the same file system
# so we must have an abstraction with reference count
function _get_ptr_ref(host::String, port::Integer, user::String="", incr::Bool=true)
    key = (host, port, user)
    if(haskey(hdfs_fsstore, key))
        arr = hdfs_fsstore[key]
        if(arr[1] > 0)
            incr && (arr[1] += 1)
            return key, arr
        end
    end
    key, [0, C_NULL]
end

function hdfs_connect_as_user(host::String, port::Integer, user::String) 
    key, arr = _get_ptr_ref(host, port, user)
    (0 != arr[1]) && return HdfsFS(host, port, user, arr[2])
    ptr = ccall((:hdfsConnectAsUser, _libhdfs), Ptr{Void}, (Ptr{Uint8}, Int32, Ptr{Uint8}), bytestring(host), int32(port), bytestring(user))
    (C_NULL != ptr) && (hdfs_fsstore[key] = [1, ptr])
    HdfsFS(host, port, user, ptr)
end
function hdfs_connect(host::String="default", port::Integer=0) 
    key, arr = _get_ptr_ref(host, port, "")
    (0 != arr[1]) && return HdfsFS(host, port, "", arr[2])
    ptr = ccall((:hdfsConnect, _libhdfs), Ptr{Void}, (Ptr{Uint8}, Int32), bytestring(host), int32(port))
    (C_NULL != ptr) && (hdfs_fsstore[key] = [1, ptr])
    HdfsFS(host, port, "", ptr)
end


# file control flags need to be done manually
function hdfs_open_file(fs::HdfsFS, path::String, flags::Integer, buffer_sz::Integer=0, replication::Integer=0, bsz::Integer=0)
  file = ccall((:hdfsOpenFile, _libhdfs), Ptr{Void}, (Ptr{Void}, Ptr{Uint8}, Int32, Int32, Int16, Int32), fs.ptr, bytestring(path), int32(flags), int32(buffer_sz), int16(replication), int32(bsz))
  return HdfsFile(file)
end
hdfs_open_file_read(fs::HdfsFS, path::String) = hdfs_open_file(fs, path, Base.JL_O_RDONLY)
hdfs_open_file_write(fs::HdfsFS, path::String) = hdfs_open_file(fs, path, Base.JL_O_WRONLY)
hdfs_open_file_append(fs::HdfsFS, path::String) = hdfs_open_file(fs, path, Base.JL_O_WRONLY | Base.JL_O_APPEND)

hdfs_close_file(fs::HdfsFS, file::HdfsFile) = ccall((:hdfsCloseFile, _libhdfs), Int32, (Ptr{Void}, Ptr{Void}), fs.ptr, file.ptr)

hdfs_exists(fs::HdfsFS, path::String) = ccall((:hdfsExists, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}), fs.ptr, bytestring(path))

hdfs_seek(fs::HdfsFS, file::HdfsFile, desired_pos) = ccall((:hdfsSeek, _libhdfs), Int32, (Ptr{Void}, Ptr{Void}, Int64), fs.ptr, file.ptr, desired_pos)

hdfs_tell(fs::HdfsFS, file::HdfsFile) = ccall((:hdfsTell, _libhdfs), Int64, (Ptr{Void}, Ptr{Void}), fs.ptr, file.ptr)

hdfs_read(fs::HdfsFS, file::HdfsFile, buff::Ptr{Void}, len::Integer) = ccall((:hdfsRead, _libhdfs), Int32, (Ptr{Void}, Ptr{Void}, Ptr{Void}, Int32), fs.ptr, file.ptr, buff, int32(len))
function hdfs_read(fs::HdfsFS, file::HdfsFile, len::Integer)
    buff = Array(Uint8, len) 
    if(-1 == (r = hdfs_read(fs, file, convert(Ptr{Void}, buff), len)))
        error("error reading file: -1")
    end
    #println("read ", r, " bytes")
    buff
end

hdfs_pread(fs::HdfsFS, file::HdfsFile, position::Int64, buff::Ptr{Void}, len::Integer) = ccall((:hdfsPread, _libhdfs), Int32, (Ptr{Void}, Ptr{Void}, Int64, Ptr{Void}, Int32), fs.ptr, file.ptr, position, buff, len)
function hdfs_pread(fs::HdfsFS, file::HdfsFile, position::Int64, len::Integer)
    local buff = Array(Uint8, len) 
    if(-1 == (r = hdfs_pread(fs, file, position, buff, len)))
        error("error reading file: -1")
    end
    #print("read ",r," bytes\n")
    buff
end

#can be passed an ASCIIString (length not necessary in that case)
hdfs_write(fs::HdfsFS, file::HdfsFile, buff::Ptr{Void}, len::Integer) = ccall((:hdfsWrite, _libhdfs), Int32, (Ptr{Void}, Ptr{Void}, Ptr{Void}, Int32), fs.ptr, file.ptr, buff, int32(len))
hdfs_write(fs::HdfsFS, file::HdfsFile, buff::ASCIIString, len::Integer) = hdfs_write(fs, file, bytestring(buff), len)
hdfs_write(fs::HdfsFS, file::HdfsFile, buff::ASCIIString) = hdfs_write(fs, file, bytesteing(buff), length(buff))

hdfs_flush(fs::HdfsFS, file::HdfsFile) = ccall((:hdfsFlush, _libhdfs), Int32, (Ptr{Void}, Ptr{Void}), fs.ptr, file.ptr)

hdfs_available(fs::HdfsFS, file::HdfsFile) = ccall((:hdfsAvailable, _libhdfs), Int32, (Ptr{Void},Ptr{Void}), fs.ptr, file.ptr)

hdfs_copy(srcFS::HdfsFS, src::String, dstFS::HdfsFS, dst::String) = ccall((:hdfsCopy, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, Ptr{Void}, Ptr{Uint8}), srcFS.ptr, bytestring(src), dstFS.ptr, bytestring(dst))

hdfs_move(srcFS::HdfsFS, src::String, dstFS::HdfsFS, dst::String) = ccall((:hdfsMove, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, Ptr{Void}, Ptr{Uint8}), srcFS.ptr, bytestring(src), dstFS.ptr, bytestring(dst))

hdfs_delete(fs::HdfsFS, path::String) = ccall((:hdfsDelete, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}), fs.ptr, bytestring(path))

hdfs_rename(fs::HdfsFS, old_path::String, new_path::String) = ccall((:hdfsRename, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}), fs.ptr, bytestring(old_path), bytestring(new_path))

hdfs_get_working_directory(fs::HdfsFS, buff::Ptr{Uint8}, buff_sz::Integer) = ccall((:hdfsGetWorkingDirectory, _libhdfs), Ptr{Uint8}, (Ptr{Void}, Ptr{Uint8}, Int32), fs.ptr, buff, int32(buff_sz))
function hdfs_get_working_directory(fs::HdfsFS, buff_sz::Integer)
    buff = Array(Uint8, buff_sz)
    path = hdfs_get_working_directory(fs, buff, buff_sz)
    if(C_NULL == path)
        error("Error getting working directory")
    end
    return bytestring(path)
end
hdfs_get_working_directory(fs::HdfsFS) = hdfs_get_working_directory(fs, 1024)

hdfs_set_working_directory(fs::HdfsFS, path::String) = ccall((:hdfsSetWorkingDirectory, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}), fs.ptr, bytestring(path))

hdfs_create_directory(fs::HdfsFS, path::String) = ccall((:hdfsCreateDirectory, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}), fs.ptr, bytestring(path))

hdfs_set_replication(fs::HdfsFS, path::String, replication::Integer)=ccall((:hdfsSetReplication, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, Int16), fs.ptr, bytestring(path), int16(replication))

function hdfs_list_directory(fs::HdfsFS, path::String)
    num_entries = zeros(Int32, 1)
    file_info_list = ccall((:hdfsListDirectory, _libhdfs), Ptr{c_hdfsfileinfo}, (Ptr{Void}, Ptr{Uint8}, Ptr{Int32}), fs.ptr, bytestring(path), num_entries)
    if(C_NULL == file_info_list)
        error(string("Error listing path ", path))
    end
    HdfsFileInfoList(file_info_list, num_entries[1]) 
end

hdfs_get_path_info(fs::HdfsFS, path::String) = HdfsFileInfo(ccall((:hdfsGetPathInfo, _libhdfs), Ptr{c_hdfsfileinfo}, (Ptr{Void}, Ptr{Uint8}), fs.ptr, bytestring(path)))

function hdfs_get_hosts(fs::HdfsFS, path::String, start::Integer, length::Integer)
    c_ptr = ccall((:hdfsGetHosts, _libhdfs), Ptr{Ptr{Ptr{Uint8}}}, (Ptr{Void}, Ptr{Uint8}, Int64, Int64), fs.ptr, bytestring(path), int64(start), int64(length))
    if(C_NULL == c_ptr)
        error(string("Error getting hosts for file", path))
    end

    i = 1
    ret_vals = Array(Array{ASCIIString,1}, 0)
    while true
        h_list = unsafe_load(c_ptr, i)
        (h_list == C_NULL) && break
        
        j = 1
        arr = Array(ASCIIString, 0)
        while true
            hname = unsafe_load(h_list, j)
            (hname == C_NULL) && break
            push!(arr, bytestring(hname))
            #print(bytestring(hname), ", ")
            j += 1
        end
        push!(ret_vals, arr)
        #println("")
        i += 1
    end

    ccall((:hdfsFreeHosts, _libhdfs), Void, (Ptr{Ptr{Ptr{Uint8}}},), c_ptr)
    ret_vals
end


hdfs_get_default_block_size(fs::HdfsFS) = ccall((:hdfsGetDefaultBlockSize, _libhdfs), Int64, (Ptr{Void},), fs.ptr)

hdfs_get_capacity(fs::HdfsFS) = ccall((:hdfsGetCapacity, _libhdfs), Int64, (Ptr{Void},), fs.ptr)

hdfs_get_used(fs::HdfsFS) = ccall((:hdfsGetUsed, _libhdfs), Int64, (Ptr{Void},), fs.ptr)

hdfs_chown(fs::HdfsFS, path::String, owner::String, group::String) = ccall((:hdfsChown, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, Ptr{Uint8}, Ptr{Uint8}), fs.ptr, bytestring(path), bytestring(owner), bytestring(group))

hdfs_chmod(fs::HdfsFS, path::String, mode::Int16) = ccall((:hdfsChmod, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, Int16), fs.ptr, bytestring(path), mode)

hdfs_utime(fs::HdfsFS, path::String, mtime::Integer, atime::Integer) = ccall((:hdfsUtime, _libhdfs), Int32, (Ptr{Void}, Ptr{Uint8}, TimeT, TimeT), fs.ptr, path, convert(TimeT, mtime), convert(TimeT, atime))

end

