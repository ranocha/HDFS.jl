##
# sample test program to produce monthly aggregate count of smileys
# used in tweets between year 2006 to 2009, based on data from infochimps.
# 
# As an example, we can use the following commands to determine how happy
# twitter users have been over time by counting smileys.
#
# 1. bring up julia on all hadoop data nodes
#       julia --machinefile ${HADOOP_HOME}/conf/slaves
# 2. load this file (assuming file present in cwd)
#       julia> require("twitter_test_smileys.jl")
# 3. we would use the daily twitter summary data from infochimps 
#    data source: http://www.infochimps.com/datasets/twitter-census-conversation-metrics-one-year-of-urls-hashtags-sm--2
#    ensure that the daily summary file is available at /twitter_daily_summary.tsv
#
# 4. run the test function
#    julia> do_smiley_tests("/twitter_daily_summary.tsv")
#
#    or, follow the steps below to do it step by step (or if graphics support is not available for plots)
#
# 5. let's count the smiley occurences in stages (monthly, yearly, total).
#    this would demonstrate how we can use results from earlier maps in further map-reduce operations.
#
#    first, get a monthly summary
#    julia> j_mon = mapreduce("/twitter_daily_summary.tsv", find_smiley, map_monthly, collect_monthly)
#
#    next, once the above is done, get a yearly summary from the monthly data
#    julia> j2 = mapreduce(j_mon, find_monthly, map_yearly_from_monthly, collect_yearly)
#
#    last, when the obove is done, get the total counts from the yearly data
#    we also have a reduce step here to get the final result on to the master node
#    julia> j_fin = mapreduce(j2, find_yearly, map_total_from_yearly, collect_total, reduce_total)
#
#    if we didn't need the monthly summary, the yearly summary could have been gotten more efficiently as:
#    julia> j_fin = mapreduce("/twitter_daily_summary.tsv", find_smiley, map_total, collect_total, reduce_total)
#
# 6. get the total result out
#    julia> wait(j_fin)
#    julia> smileys = results(j_fin)[2]
#    julia> happy_smileys = [":)", ":=)", "=)", "-)", ":-)", "(:", "(=:", "(=", "(-", "(-:"]
#    julia> sad_smileys = [":(", ":=(", "=(", "-(", ":-(", "):", ")=:", ")=", ")-", ")-:"]
# 7. count the happy and not_so_happy tweets
#    julia> happy = sum(map(x->get(smileys, x, 0), happy_smileys))
#    julia> sad = sum(map(x->get(smileys, x, 0), sad_smileys))
#    julia> println("people tweet more when they are ", (happy > sad) ? "happy":"sad")
#
# 8. get the monthly result out
#    julia> smileys = results(j_mon)[2]
# 9. count the happy and not_so_happy tweets
#    julia> happy = sum(map(x->get(smileys, x, zeros(Int,12*5)), happy_smileys))
#    julia> sad = sum(map(x->get(smileys, x, zeros(Int,12*5)), sad_smileys))
#    julia> hq = map(x->(sad[x]>0)?(happy[x]/sad[x]):'?', 1:length(happy))
#    julia> println("twitter happiness quotient:")
#    julia> println(hq)
# 10. plot the results 

using HDFS
using Gaston

##
# find smiley records from HDFS CSV file
find_smiley(jr::HdfsReaderIter, next_rec_pos) = hdfs_find_rec_csv(jr, next_rec_pos, '\n', '\t', 1024, ("smiley", nothing, nothing, nothing))


##
# for finding total counts across all years
function map_total(rec)
    ((nothing == rec) || (length(rec) == 0)) && return []
    [(rec[4], int(rec[3]))]
end

# TODO: define standard collectors
function collect_total(results, rec)
    (length(rec) == 0) && return results
    smiley, cnt = rec

    try
        results[smiley] += cnt
    catch
        (nothing == results) && (results = Dict{String, Int}())
        results[smiley] = cnt
    end
    results
end

function reduce_total(reduced, results...)
    (nothing == reduced) && (reduced = Dict{String, Int}())
    
    for d in results
        (nothing == d) && continue
        for (smiley,cnt) in d
            haskey(reduced, smiley) ? (reduced[smiley] += cnt) : (reduced[smiley] = cnt)
        end
    end
    reduced
end


##
# for finding annual counts
function map_yearly(rec)
    ((nothing == rec) || (length(rec) == 0)) && return []

    ts = rec[2]
    ts_year = int(ts[1:4])
    [(rec[4], (ts_year-2006+1), int(rec[3]))]
end

# TODO: define standard collectors
function collect_yearly(results, rec)
    (length(rec) == 0) && return results
    smiley, year_idx, cnt = rec

    local yearly::Vector{Int}
    try
        yearly = getindex(results, smiley)
    catch
        (nothing == results) && (results = Dict{String, Vector{Int}}())
        yearly = zeros(Int, 5)
        results[smiley] = yearly
    end

    yearly[year_idx] += cnt
    results
end

function reduce_yearly(reduced, results...)
    (nothing == reduced) && (reduced = Dict{String, Vector{Int}}())
    
    for d in results
        (nothing == d) && continue
        for (smiley,yearly) in d
            haskey(reduced, smiley) ? (reduced[smiley] += yearly) : (reduced[smiley] = yearly)
        end
    end
    reduced
end

find_yearly(jr::MapResultReaderIter, iter_status) = mr_result_find_rec(jr, iter_status)
map_total_from_yearly(rec) = [(rec[1], sum(rec[2]))]


##
# for finding monthly counts
function map_monthly(rec)
    ((nothing == rec) || (length(rec) == 0)) && return []

    ts = rec[2]
    ts_year = int(ts[1:4])
    ts_mon = int(ts[5:6])
    month_idx = 12*(ts_year-2006) + ts_mon  # twitter begun from 2006
    [(rec[4], month_idx, int(rec[3]))]
end

# TODO: define standard collectors
function collect_monthly(results, rec)
    (length(rec) == 0) && return results
    smiley, month_idx, cnt = rec

    local monthly::Vector{Int}
    try
        monthly = getindex(results, smiley)
    catch
        (nothing == results) && (results = Dict{String, Vector{Int}}())
        # represent 5 years worth of monthly data
        monthly = zeros(Int, 12*5)
        results[smiley] = monthly
    end

    monthly[month_idx] += cnt
    results
end

function reduce_monthly(reduced, results...)
    (nothing == reduced) && (reduced = Dict{String, Vector{Int}}())
    
    for d in results
        (nothing == d) && continue
        for (smiley,monthly) in d
            haskey(reduced, smiley) ? (reduced[smiley] += monthly) : (reduced[smiley] = monthly)
        end
    end
    reduced
end

find_monthly(jr::MapResultReaderIter, iter_status) = mr_result_find_rec(jr, iter_status)
function map_yearly_from_monthly(rec) 
    b = rec[2]
    ret = Array(Tuple,0)
    for i in 1:(length(b)/12)
        slice_end = 12*i
        push!(ret, (rec[1], i, sum(b[1+slice_end-12:slice_end])))
    end
    ret
end

 
function do_smiley_tests(furl::String)
    println("starting mapreduce jobs...")
    j_mon = mapreduce(furl, find_smiley, map_monthly, collect_monthly, reduce_monthly)
    j2 = mapreduce(j_mon, find_monthly, map_yearly_from_monthly, collect_yearly)
    j_fin = mapreduce(j2, find_yearly, map_total_from_yearly, collect_total, reduce_total)

    println("waiting for jobs to finish...")
    wait(j_fin)
    println("time taken (total time, wait time, run time):")
    println("\tmapreduce daily to monthly: $(times(j_mon))")
    println("\tmap monthly to yearly:      $(times(j2))")
    println("\tmapreduce yearly to total:  $(times(j_fin))")
    println("")
    println("results:")
    smileys = results(j_fin)[2]
    happy_smileys = [":)", ":=)", "=)", "-)", ":-)", "(:", "(=:", "(=", "(-", "(-:"]
    sad_smileys = [":(", ":=(", "=(", "-(", ":-(", "):", ")=:", ")=", ")-", ")-:"]

    happy = sum(map(x->get(smileys, x, 0), happy_smileys))
    sad = sum(map(x->get(smileys, x, 0), sad_smileys))
    println("people tweet more when they are ", (happy > sad) ? "happy":"sad")

    smileys = results(j_mon)[2]
    happy = sum(map(x->get(smileys, x, zeros(Int,12*5)), happy_smileys))
    sad = sum(map(x->get(smileys, x, zeros(Int,12*5)), sad_smileys))
    hq = map(x->(sad[x]>0)?(happy[x]/sad[x]):0.0, 1:length(happy))
    hq = convert(Array{Float64,1}, hq)
    println("twitter happiness quotient:")
    println(hq[6:46])
    println("plot coming up...")
    set_terminal("x11")
    plot(hq[6:46], 
           "color","blue",
           "marker","ecircle",
           "linewidth",2,
           "pointsize",1.1,
           "title","twitter happiness index",
           "xlabel","months",
           "ylabel","): | (:",
           "box","inside horizontal left top")
end 
