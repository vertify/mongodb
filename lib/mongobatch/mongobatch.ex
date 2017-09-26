defmodule MONGOBATCH do
  require Logger

  @maxdocsize 16000000

  def submittomongo(mpid, submitteddocument) do

    # Determine write type
    {documentwritetype, numwrittenitems} = cond do
      Map.has_key?(submitteddocument, :documents) ->
        {:insert, length(submitteddocument.documents)}
      Map.has_key?(submitteddocument, :updates) ->
        {:update, length(submitteddocument.updates)}
      Map.has_key?(submitteddocument, :deletes) ->
        {:delete, length(submitteddocument.deletes)}
    end

    # Save Collection value
    collection = submitteddocument[documentwritetype]

    # Add _id values to inserted documents
    {{insertedidlist, insertrecords}, submitteddocument} = if documentwritetype == :insert do
      insertcandidates = submitteddocument.documents
      insertrecordstuples = Enum.map(
        insertcandidates,
        fn(x) ->
          # Logger.debug("Batch insert candidate: #{inspect x}")
          if Map.has_key?(x, "_id") do
            {%{"_id" => x["_id"]}, x}
          else
            insertid = Mongo.object_id
            {%{"_id" => insertid}, Map.put(x, "_id", insertid)}
          end
        end
        # fn(x) ->
        #   insertid = Mongo.object_id
        #   {%{_id: insertid}, Map.put(x, :_id, insertid)}
        # end
      )
      {insertedidlist, insertrecords} = Enum.unzip(insertrecordstuples)
      # IO.puts("Insert Candidates:")
      # IO.inspect(submitteddocument)
      {{insertedidlist, insertrecords}, %{submitteddocument | documents: insertrecords}}
    else
      {{[], []}, submitteddocument}
    end

    # Reorder fields to make sure command is first
    submitteddocument =
      submitteddocument
      |> Map.drop([documentwritetype])
      |> Enum.into([])
      |> List.insert_at(0, {documentwritetype, collection})
      # |> IO.inspect

    # Execute proper Mongo command based on documentwritetype
    {:ok, mongowriteresult} = Mongo.command(mpid, submitteddocument)
    # Changing code to return matching list of status instead of mongo result
    # Will probably have to undo this eventually
    # mongowriteresult

    if mongowriteresult["ok"] == 1 do
      # Create optimistic base result array
      resultbaselist =
        Stream.cycle([%{ok: 1}])
        |> Enum.take(numwrittenitems)

      resultbaselist = if documentwritetype == :insert do
        Enum.zip(resultbaselist, insertedidlist)
          |> Enum.map(
            fn({k, v}) ->
              Map.merge(k, v)
            end
          )
      else
        resultbaselist
      end

      individualwriteresults = if (Map.has_key?(mongowriteresult, "writeErrors")) do
        # Extract error list
        errorlist = mongowriteresult["writeErrors"]
        # Change base indices to errors according to error list
        returnresultlist = Enum.reduce(
          errorlist,
          resultbaselist,
          fn(x, resultcandidate) ->
            resultcandidate = List.replace_at(
              resultcandidate,
              x["index"],
              %{ok: 0, code: x["code"], errInfo: x["errInfo"], errmsg: x["errmsg"]}
            )
          end
        )
        returnresultlist
      else
        resultbaselist
      end

      writeconcernerror = if (Map.has_key?(mongowriteresult, "writeConcernError")) do
        [%{writeConcernError: true, error: mongowriteresult["writeConcernError"]}]
      else
        []
      end

      Enum.concat(individualwriteresults, writeconcernerror)
    else
      # Catastrophic error...  ABORT! ABORT!
      [mongowriteresult]
    end
  end
  #---------------------------------------------------------------------------#
  def findpagebreaks(docsizelist, pagebreaklist) do
    # Calculate sum of doc sizes in list
    totaldocsize = Enum.sum(docsizelist)
    if totaldocsize < @maxdocsize do
      pagebreaklist
    else
      # Create list of total accumulated doc sizes for each doc, inclusive
      totalsizelist = Enum.scan(
        docsizelist,
        0,
        &(&1 + &2)
      )

      # Find index of first item where docsize >= maxdocsize, then step back one to below maxdocsize
      maxpagesizeindex = Enum.find_index(totalsizelist, fn(x) -> x >= @maxdocsize end) - 1
      pagebreaklist = Enum.concat(pagebreaklist, [ maxpagesizeindex ])
      # Split at maxpagesizeindex
      {page, restofdocsizelist} = Enum.split(docsizelist, maxpagesizeindex)
      # Recurse on rest of data
      findpagebreaks(restofdocsizelist, pagebreaklist)
    end
  end
  #---------------------------------------------------------------------------#
  def getpagebreaks(listofdocuments) do
    # First, Encode submitted docs
    encodeddocs = Enum.map(
      listofdocuments,
      fn(x) ->
        BSON.encode(x)
      end
    )

    # Next, create list of doc sizes
    docsizes = Enum.map(
      encodeddocs,
      fn(x) ->
        #byte_size(x)
        IO.iodata_length(x)
      end
    )

    # Find page breaks and return
    findpagebreaks(docsizes, [])
  end
  #---------------------------------------------------------------------------#
  def insertpages(mpid, inserttemplate, documentlist, pageindexes, resultset) do
    # Seperate page of data
    sepindex = Enum.at(pageindexes, 0)
    {pageofdocs, restofdocs} = Enum.split(documentlist, sepindex)

    #Create document to submit for processing
    submissiondocument = %{inserttemplate | documents: pageofdocs}

    # Submit to Mongo
    resultset = Enum.concat(resultset, [submittomongo(mpid, submissiondocument)])

    # Now delete just used page index
    nextpageindexlist = Enum.drop(pageindexes, 1)

    if length(nextpageindexlist) > 0 do
      # Recurse on remaining docs
      insertpages(mpid, inserttemplate, restofdocs, nextpageindexlist, resultset)
    else
      # Submit last page to mongo
      lastpagesubmission = %{inserttemplate | documents: restofdocs}
      resultset = Enum.concat(resultset, [submittomongo(mpid, lastpagesubmission)])
    end
  end
  #---------------------------------------------------------------------------#
  def updatepages(mpid, updatetemplate, documentlist, pageindexes, resultset) do
    # Seperate page of data
    sepindex = Enum.at(pageindexes, 0)
    {pageofdocs, restofdocs} = Enum.split(documentlist, sepindex)

    #Create document to submit for processing
    submissiondocument = %{updatetemplate | updates: pageofdocs}

    # Submit to Mongo
    resultset = Enum.concat(resultset, [submittomongo(mpid, submissiondocument)])

    # Now delete just used page index
    nextpageindexlist = Enum.drop(pageindexes, 1)

    if length(nextpageindexlist) > 0 do
      # Recurse on remaining docs
      updatepages(mpid, updatetemplate, restofdocs, nextpageindexlist, resultset)
    else
      # Submit last page to mongo
      lastpagesubmission = %{updatetemplate | updates: restofdocs}
      resultset = Enum.concat(resultset, [submittomongo(mpid, lastpagesubmission)])
    end
  end
  #---------------------------------------------------------------------------#
  def deletepages(mpid, deletetemplate, documentlist, pageindexes, resultset) do
    # Seperate page of data
    sepindex = Enum.at(pageindexes, 0)
    {pageofdocs, restofdocs} = Enum.split(documentlist, sepindex)

    #Create document to submit for processing
    submissiondocument = %{deletetemplate | deletes: pageofdocs}

    # Submit to Mongo
    resultset = Enum.concat(resultset, [submittomongo(mpid, submissiondocument)])

    # Now delete just used page index
    nextpageindexlist = Enum.drop(pageindexes, 1)

    if length(nextpageindexlist) > 0 do
      # Recurse on remaining docs
      deletepages(mpid, deletetemplate, restofdocs, nextpageindexlist, resultset)
    else
      # Submit last page to mongo
      lastpagesubmission = %{deletetemplate | deletes: restofdocs}
      resultset = Enum.concat(resultset, [submittomongo(mpid, lastpagesubmission)])
    end
  end
  #---------------------------------------------------------------------------#
  def combineresults(resultset) do
    # Changing code to return matching list of status instead of mongo result
    # Will probably have to undo this eventually
    # Recalculate indexes of writeErrors and generate overall result of paged writes
    # finalresult = Enum.reduce(
    #   resultset,
    #   BatchResponse.defaults(),
    #   fn(x, totalresult) ->
    #     if x["ok"] == 1 do
    #       # Recalculate writeError indices based on pages-so-far offset
    #       if (Map.has_key?(x, "writeErrors")) do
    #         recalcwriteErrorindexes = Enum.map(
    #           x["writeErrors"],
    #           fn(we) ->
    #             update_in(we["index"], &(&1 + totalresult.results.n))
    #           end
    #         )
    #         # Update totalresults writeErrors list
    #         totalresult = update_in(totalresult.results.writeErrors, &Enum.concat(&1, recalcwriteErrorindexes))
    #       end
    #       # if page result has nModified, update BatchResponse
    #       if (Map.has_key?(x, "nModified")) do
    #         totalresult = update_in(totalresult.results.nModified, &(&1 + x["nModified"]))
    #       end
    #       # if page result has upserted list, recalculate indices and update BatchResponse
    #       if (Map.has_key?(x, "upserted")) do
    #         recalcupsertedindexes = Enum.map(
    #           x["upserted"],
    #           fn(u) ->
    #             update_in(u["index"], &(&1 + totalresult.results.n))
    #           end
    #         )
    #         totalresult = update_in(totalresult.results.upserted, &Enum.concat(&1, recalcupsertedindexes))
    #       end
    #       # Update totalresults count
    #       if (Map.has_key?(x, "n")) do
    #         totalresult = update_in(totalresult.results.n, &(&1 + x["n"]))
    #       end
    #       # Update totalresults writeConcernErrors list
    #       if (Map.has_key?(x, "writeConcernError")) do
    #         totalresult = update_in(totalresult.results.writeConcernErrors, &Enum.concat(&1, [x["writeConcernError"]]))
    #       end
    #       totalresult
    #     else
    #       totalresult = %{totalresult | ok: 0}
    #       %{totalresult | errors: x}
    #     end
    #   end
    # )
    # if (finalresult.ok == 1) do
    #   finalresult = Map.delete(finalresult, :error)
    # end
    # finalresult

    {write_concern, documents} = Enum.partition(Enum.concat(resultset), fn map ->
      Map.has_key? map, :writeConcernError
    end)
    %{documents: documents, write_concern_errors: write_concern}
  end
  #---------------------------------------------------------------------------#
  # def insert(mpid, insertdocument) do
  #   # Get maxdocsize page breaks
  #   fullpageindices = getpagebreaks(insertdocument.documents)
  #
  #   resultset = if Enum.empty?(fullpageindices) do
  #     [submittomongo(mpid, insertdocument)]
  #   else
  #     inserttemplate = %{insertdocument | documents: []}
  #     insertpages(mpid, inserttemplate, insertdocument.documents, fullpageindices, [])
  #   end
  #   combineresults(resultset)
  # end
  #---------------------------------------------------------------------------#
  # def update(mpid, updatedocument) do
  #   # Get maxdocsize page breaks
  #   fullpageindices = getpagebreaks(updatedocument.updates)
  #
  #   resultset = if Enum.empty?(fullpageindices) do
  #     [submittomongo(mpid, updatedocument)]
  #   else
  #     updatetemplate = %{updatedocument | updates: []}
  #     updatepages(mpid, updatetemplate, updatedocument.updates, fullpageindices, [])
  #   end
  #   combineresults(resultset)
  # end
  #---------------------------------------------------------------------------#
  # def delete(mpid, deletedocument) do
  #   # Get maxdocsize page breaks
  #   fullpageindices = getpagebreaks(deletedocument.deletes)
  #
  #   resultset = if Enum.empty?(fullpageindices) do
  #     [submittomongo(mpid, deletedocument)]
  #   else
  #     deletetemplate = %{deletedocument | deletes: []}
  #     deletepages(mpid, deletetemplate, deletedocument.deletes, fullpageindices, [])
  #   end
  #   combineresults(resultset)
  # end
  #---------------------------------------------------------------------------#
  def batchwrite(mpid, writedocument) do
    # Parse write document
    writecollection = writedocument.collection
    writeconcern = writedocument.writeConcern
    writeorder = writedocument.ordered

    # Process writes
    if writeorder == false do
      # Sort by write type
      {insertdoclist, updatedoclist, deletedoclist} = BatchWriteSorter.sortunordered(writedocument.writes)

      result = if not Enum.empty? insertdoclist do
        # Process inserts first
        # Build insert document template
        inserttemplate = %{BatchInsert.defaults() | insert: writecollection}
        inserttemplate = %{inserttemplate | writeConcern: writeconcern}
        inserttemplate = %{inserttemplate | ordered: writeorder}
        # Get maxdocsize page breaks
        insertfullpageindices = getpagebreaks(insertdoclist)
        # Write inserts
        insertresultset = if Enum.empty?(insertfullpageindices) do
          [submittomongo(mpid, %{inserttemplate | documents: insertdoclist})]
        else
          insertpages(mpid, inserttemplate, insertdoclist, insertfullpageindices, [])
        end
        # IO.inspect insertresultset
        %{insertresults: combineresults(insertresultset)}
      else
        %{}
      end

      result = if not Enum.empty? updatedoclist do
        # Process updates second
        updatetemplate = %{BatchUpdate.defaults() | update: writecollection}
        updatetemplate = %{updatetemplate | writeConcern: writeconcern}
        updatetemplate = %{updatetemplate | ordered: writeorder}
        # Get maxdocsize page breaks
        updatefullpageindices = getpagebreaks(updatedoclist)
        # Write updates
        updateresultset = if Enum.empty?(updatefullpageindices) do
          [submittomongo(mpid, %{updatetemplate | updates: updatedoclist})]
        else
          updatepages(mpid, updatetemplate, updatedoclist, updatefullpageindices, [])
        end
        Map.put(result, :updateresults, combineresults(updateresultset))
      else
        result
      end

      if not Enum.empty? deletedoclist do
        # Process deletes last
        deletetemplate = %{BatchDelete.defaults() | delete: writecollection}
        deletetemplate = %{deletetemplate | writeConcern: writeconcern}
        deletetemplate = %{deletetemplate | ordered: writeorder}
        # Get maxdocsize page breaks
        deletefullpageindices = getpagebreaks(deletedoclist)
        # Write deletes
        deletes = Enum.map(deletedoclist,
          fn deletedoc ->
            Map.put(deletedoc, :limit, 0)
          end)
        deleteresultset = if Enum.empty?(deletefullpageindices) do
          [submittomongo(mpid, %{deletetemplate | deletes: deletes})]
        else
          deletepages(mpid, deletetemplate, deletes, deletefullpageindices, [])
        end
        Map.put(result, :deleteresults, combineresults(deleteresultset))
      else
        result
      end
    else
      # Parse writedocument into ordered list of contiguous type documents
      orderedwritegroupmaps = BatchWriteSorter.sortordered(writedocument)
      # Batch write each writegroup list and return total results
      Enum.reduce(
        orderedwritegroupmaps,
        [],
        fn(x, resultlist) ->
          case x.type do
            "insert" ->
              # Process inserts
              inserttemplate = %{BatchInsert.defaults() | insert: writecollection}
              inserttemplate = %{inserttemplate | writeConcern: writeconcern}
              inserttemplate = %{inserttemplate | ordered: writeorder}
              # Get maxdocsize page breaks
              insertfullpageindices = getpagebreaks(x.writes)
              # Write inserts
              insertresultset = if Enum.empty?(insertfullpageindices) do
                [submittomongo(mpid, %{inserttemplate | documents: x.writes})]
              else
                insertpages(mpid, inserttemplate, x.writes, insertfullpageindices, [])
              end
              resultlist = Enum.concat(resultlist, combineresults(insertresultset))

            "update" ->
              # Process updates
              updatetemplate = %{BatchUpdate.defaults() | update: writecollection}
              updatetemplate = %{updatetemplate | writeConcern: writeconcern}
              updatetemplate = %{updatetemplate | ordered: writeorder}
              # Get maxdocsize page breaks
              updatefullpageindices = getpagebreaks(x.writes)
              # Write updates
              updateresultset = if Enum.empty?(updatefullpageindices) do
                [submittomongo(mpid, %{updatetemplate | updates: x.writes})]
              else
                updatepages(mpid, updatetemplate, x.writes, updatefullpageindices, [])
              end
              resultlist = Enum.concat(resultlist, combineresults(updateresultset))

            "delete" ->
              # Process deletes last
              deletetemplate = %{BatchDelete.defaults() | delete: writecollection}
              deletetemplate = %{deletetemplate | writeConcern: writeconcern}
              deletetemplate = %{deletetemplate | ordered: writeorder}
              # Get maxdocsize page breaks
              deletefullpageindices = getpagebreaks(x.writes)
              # Write deletes
              deleteresultset = if Enum.empty?(deletefullpageindices) do
                [submittomongo(mpid, %{deletetemplate | deletes: x.writes})]
              else
                deletepages(mpid, deletetemplate, x.writes, deletefullpageindices, [])
              end
              resultlist = Enum.concat(resultlist, combineresults(deleteresultset))
          end
        end
      )
    end
  end
  #---------------------------------------------------------------------------#
end
