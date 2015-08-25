-- 1. Update latest_update field to new date 
BEGIN
   EXECUTE IMMEDIATE 'ALTER TABLE vocabulary DROP COLUMN latest_update';
EXCEPTION WHEN OTHERS THEN NULL;
END;
ALTER TABLE vocabulary ADD latest_update DATE;
UPDATE vocabulary SET latest_update=to_date('20150706','yyyymmdd'), vocabulary_version='CVX code set' WHERE vocabulary_id = 'CVX';
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

--3. update vocabulary version according to CVX table
UPDATE vocabulary SET latest_update=(SELECT MAX(last_updated_date) FROM CVX) WHERE vocabulary_id = 'CVX';
UPDATE vocabulary SET vocabulary_version='CVX code set '||latest_update WHERE vocabulary_id = 'CVX';

--4. Insert into concept_stage
INSERT INTO concept_stage (concept_name,
                           vocabulary_id,
                           domain_id,
                           concept_class_id,
                           standard_concept,
                           concept_code,
                           valid_start_date,
                           valid_end_date,
                           invalid_reason)
   SELECT SUBSTR (full_vaccine_name, 1, 255) AS concept_name,
          'CVX' AS vocabulary_id,
          'Drug' AS domain_id,
          'Drg Class' AS concept_class_id,
          'C' AS standard_concept,
          cvx_code AS concept_code,
          (SELECT MIN(concept_date) FROM CVX_DATES d WHERE D.CVX_CODE=C.CVX_CODE) AS valid_start_date, --get concept date from true source
          TO_DATE ('20991231', 'yyyymmdd') AS valid_end_date,
          NULL AS invalid_reason
     FROM CVX c;
COMMIT;			

--5 load into concept_synonym_stage
INSERT INTO concept_synonym_stage (synonym_concept_id,
                                   synonym_concept_code,
                                   synonym_name,
                                   synonym_vocabulary_id,
                                   language_concept_id)
   SELECT DISTINCT NULL AS synonym_concept_id,
                   cvx_code AS synonym_concept_code,
                   DESCRIPTION AS synonym_name,
                   'CVX' AS synonym_vocabulary_id,
                   4093769 AS language_concept_id                   -- English
     FROM (SELECT full_vaccine_name, short_description, cvx_code FROM CVX)
          UNPIVOT
             (DESCRIPTION  --take both full_vaccine_name and short_description
             FOR DESCRIPTIONS
             IN (full_vaccine_name, short_description));			  
COMMIT;

-----------------------------------------------

--?? Update concept_id in concept_stage from concept for existing concepts
UPDATE concept_stage cs
    SET cs.concept_id=(SELECT c.concept_id FROM concept c WHERE c.concept_code=cs.concept_code AND c.vocabulary_id=cs.vocabulary_id)
    WHERE cs.concept_id IS NULL
;
COMMIT;

--?? Reinstate constraints and indices
ALTER INDEX idx_cs_concept_code REBUILD NOLOGGING;
ALTER INDEX idx_cs_concept_id REBUILD NOLOGGING;
ALTER INDEX idx_concept_code_1 REBUILD NOLOGGING;
ALTER INDEX idx_concept_code_2 REBUILD NOLOGGING;

-- At the end, the three tables concept_stage, concept_relationship_stage and concept_synonym_stage should be ready to be fed into the generic_update.sql script		