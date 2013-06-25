module HDFS

import  Base.start, Base.done, Base.next, 
        Base.wait,
        Base.nb_available, Base.read, Base.eof, Base.position, Base.seekstart, Base.seekend, Base.skip, Base.seek, Base.peek

export  hdfs_connect,
        hdfs_exists, hdfs_delete, 
        hdfs_flush, hdfs_get_capacity, hdfs_get_default_block_size, hdfs_get_path_info, hdfs_get_used, hdfs_is_directory,
        hdfs_cd, hdfs_pwd, hdfs_list_directory, hdfs_mkdir, 
        hdfs_open, hdfs_close, hdfs_rename, hdfs_copy, hdfs_move,
        hdfs_pread, hdfs_read, hdfs_seek, hdfs_tell, hdfs_write, hdfs_available,
        hdfs_set_replication, hdfs_blocks,
        # from hdfs_types.jl
        HDFS_OBJ_FILE, HDFS_OBJ_DIR, HDFS_OBJ_INVALID,
        HdfsFS, HdfsFile, HdfsFileInfo, 
        # from hdfs_jobs.jl
        dmap, dmapreduce, results, status, unload, wait, times, JobId, start_workers,
        # from hdfs_reader.jl
        MRInput, MRMapInput, MRFileInput,
        HdfsReader, HdfsBlockStream, HdfsBlockReader, nb_available, read, eof, position, seekstart, seekend, skip, seek, peek, hdfs_read_all, hdfs_read_chunk, 
        MapResultReader

using ChainedVectors
using URLParse
using PTools
using DataFrames

global _debug = false
function _set_debug(d)
    global _debug
    _debug = d
end

include("hdfs_types.jl")
include("hdfs_reader.jl")
include("map_result_reader.jl")
include("hdfs_jobs.jl")
include("hdfs_mrutils.jl")
if(C_NULL != dlopen_e(_libhdfs))
    include("hdfs_dfs.jl")
end
end

