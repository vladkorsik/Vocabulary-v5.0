-- 1. Update latest_update field to new date 
BEGIN
   EXECUTE IMMEDIATE 'ALTER TABLE vocabulary DROP COLUMN latest_update';
EXCEPTION WHEN OTHERS THEN NULL;
END;
ALTER TABLE vocabulary ADD latest_update DATE;
UPDATE vocabulary SET (latest_update, vocabulary_version)=(select to_date(NDDF_VERSION,'YYYYMMDD'), NDDF_VERSION||' Release' from NDDF_PRODUCT_INFO) WHERE vocabulary_id='GCN_SEQNO';
COMMIT;

-- 2. Truncate all working tables and remove indices
TRUNCATE TABLE concept_stage;
TRUNCATE TABLE concept_relationship_stage;
TRUNCATE TABLE concept_synonym_stage;
ALTER SESSION SET SKIP_UNUSABLE_INDEXES = TRUE; --disables error reporting of indexes and index partitions marked UNUSABLE
ALTER INDEX idx_cs_concept_code UNUSABLE;
ALTER INDEX idx_cs_concept_id UNUSABLE;
ALTER INDEX idx_concept_code_1 UNUSABLE;
ALTER INDEX idx_concept_code_2 UNUSABLE;

--3. Add GCN_SEQNO to concept_stage from rxnconso
INSERT /*+ APPEND */ INTO  concept_stage (concept_name,
                           domain_id,
                           vocabulary_id,
                           concept_class_id,
                           standard_concept,
                           concept_code,
                           valid_start_date,
                           valid_end_date,
                           invalid_reason)
   SELECT SUBSTR (c.str, 1, 255) AS concept_name,
          'Drug' AS domain_id,
          'GCN_SEQNO' AS vocabulary_id,
          'GCN_SEQNO' AS concept_class_id,
          NULL AS standard_concept,
          c.code AS concept_code,
		 (select v.latest_update from vocabulary v where v.vocabulary_id = 'GCN_SEQNO' ) AS valid_start_date,
		 TO_DATE ('20991231', 'yyyymmdd') AS valid_end_date,
          NULL AS invalid_reason
     FROM rxnconso c
    WHERE c.sab = 'NDDF' AND c.tty = 'CDC' AND c.suppress = 'N';
COMMIT;

--4. Load into concept_relationship_stage
INSERT /*+ APPEND */ INTO  concept_relationship_stage (concept_code_1,
                                        concept_code_2,
                                        vocabulary_id_1,
                                        vocabulary_id_2,
                                        relationship_id,
                                        valid_start_date,
                                        valid_end_date,
                                        invalid_reason)
   SELECT DISTINCT gcn.code AS concept_code_1,
                   rxn.code AS concept_code_2,
                   'GCN_SEQNO' AS vocabulary_id_1,
                   'RxNorm' AS vocabulary_id_2,
                   'Maps to' AS relationship_id,
				   (select v.latest_update from vocabulary v where v.vocabulary_id = 'GCN_SEQNO') AS valid_start_date,
                   TO_DATE ('20991231', 'yyyymmdd') AS valid_end_date,
                   NULL AS invalid_reason
     FROM rxnconso gcn
          JOIN rxnconso rxn ON rxn.rxcui = gcn.rxcui AND rxn.sab = 'RXNORM' AND rxn.suppress = 'N'
    WHERE gcn.sab = 'NDDF' AND gcn.tty = 'CDC' AND gcn.suppress = 'N';
COMMIT;	 


--5. Update concept_id in concept_stage from concept for existing concepts
UPDATE concept_stage cs
    SET cs.concept_id=(SELECT c.concept_id FROM concept c WHERE c.concept_code=cs.concept_code AND c.vocabulary_id=cs.vocabulary_id)
    WHERE cs.concept_id IS NULL;


--6. Reinstate constraints and indices
ALTER INDEX idx_cs_concept_code REBUILD NOLOGGING;
ALTER INDEX idx_cs_concept_id REBUILD NOLOGGING;
ALTER INDEX idx_concept_code_1 REBUILD NOLOGGING;
ALTER INDEX idx_concept_code_2 REBUILD NOLOGGING;

-- At the end, the three tables concept_stage, concept_relationship_stage and concept_synonym_stage should be ready to be fed into the generic_update.sql script		