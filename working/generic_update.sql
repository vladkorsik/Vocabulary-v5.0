-- GATHER_TABLE_STATS
exec DBMS_STATS.GATHER_TABLE_STATS (ownname=> USER, tabname => 'concept_stage', estimate_percent => null, cascade => true);
exec DBMS_STATS.GATHER_TABLE_STATS (ownname=> USER, tabname => 'concept_relationship_stage', estimate_percent => null, cascade => true);
exec DBMS_STATS.GATHER_TABLE_STATS (ownname=> USER, tabname => 'concept_synonym_stage', estimate_percent => null, cascade => true);

-- 1. Update existing concept details from concept_stage. 
-- All fields (concept_name, domain_id, concept_class_id, standard_concept, valid_start_date and valid_end_date) are updated
-- with the exception of vocabulary_id (already there), concept_id (already there) and invalid_reason (below).
SET (concept_name, domain_id, concept_class_id, standard_concept, valid_start_date, valid_end_date) = (
  SELECT 
    cs.concept_name,
    cs.domain_id,
    cs.concept_class_id,
    cs.standard_concept, 
    CASE -- if we have a real date in concept_stage, use it. If it is only the release date, use the existing.
      WHEN cs.valid_start_date = v.latest_update THEN c.valid_start_date
      ELSE cs.valid_start_date
    END,
    cs.valid_end_date
  FROM concept_stage cs, vocabulary v
  WHERE c.concept_id=cs.concept_id -- concept exists in both, meaning, is not new. But information might be new
  AND v.vocabulary_id=cs.vocabulary_id
  -- invalid_reason is set below based on the valid_end_date
)
WHERE c.concept_id IN (SELECT concept_id FROM concept_stage)
;

COMMIT;

-- 2. Deprecate concepts missing from concept_stage and are not already deprecated. 
-- This only works for vocabularies where we expect a full set of active concepts in concept_stage.
-- If the vocabulary only updates changed concepts, this should not be run, and the update information is already dealt with in step 1.
UPDATE concept c SET
c.valid_end_date = (SELECT latest_update-1 FROM vocabulary WHERE vocabulary_id=c.vocabulary_id) -- set invalid_reason depending on the existence of replace relationship
WHERE NOT EXISTS (SELECT 1 FROM concept_stage cs WHERE cs.concept_id=c.concept_id AND cs.vocabulary_id=c.vocabulary_id)
AND c.vocabulary_id IN (SELECT vocabulary_id FROM vocabulary WHERE latest_update IS NOT NULL)
AND c.invalid_reason IS NULL
AND CASE -- all vocabularies that give us a full list of active concepts at each release we can safely assume to deprecate missing ones (THEN 1)
  WHEN c.vocabulary_id = 'SNOMED' THEN 1
  WHEN c.vocabulary_id = 'LOINC' AND c.concept_class_id='LOINC Answers' THEN 1 -- Only LOINC answers are full lists
  WHEN c.vocabulary_id = 'LOINC' THEN 0 -- LOINC gives full account of all concepts
  WHEN c.vocabulary_id = 'ICD9CM' THEN 1
  WHEN c.vocabulary_id = 'ICD9Proc' THEN 1
  WHEN c.vocabulary_id = 'RxNorm' THEN 1
  WHEN c.vocabulary_id = 'NDFRT' THEN 1
  WHEN c.vocabulary_id = 'VA Product' THEN 1
  WHEN c.vocabulary_id = 'VA Class' THEN 1
  WHEN c.vocabulary_id = 'ATC' THEN 1
  WHEN c.vocabulary_id = 'NDC' THEN 0
  WHEN c.vocabulary_id = 'SPL' THEN 0  
  WHEN c.vocabulary_id = 'MedDRA' THEN 1
  WHEN c.vocabulary_id = 'CPT4' THEN 1
  WHEN c.vocabulary_id = 'HCPCS' THEN 1
  WHEN c.vocabulary_id = 'Read' THEN 1
  ELSE 0 -- in default we will not deprecate
END = 1
;

COMMIT;

-- 3. add new concepts from concept_stage
DECLARE
 ex NUMBER;
BEGIN
  SELECT MAX(concept_id)+1 INTO ex FROM concept WHERE concept_id<500000000;
  BEGIN
    EXECUTE IMMEDIATE 'CREATE SEQUENCE v5_concept INCREMENT BY 1 START WITH ' || ex || ' NOCYCLE CACHE 20 NOORDER';
    EXCEPTION
      WHEN OTHERS THEN NULL;
  END;
END;

INSERT /*+ APPEND */ INTO concept (concept_id,
                     concept_name,
                     domain_id,
                     vocabulary_id,
                     concept_class_id,
                     standard_concept,
                     concept_code,
                     valid_start_date,
                     valid_end_date,
                     invalid_reason)
   SELECT v5_concept.NEXTVAL,
          cs.concept_name,
          cs.domain_id,
          cs.vocabulary_id,
          cs.concept_class_id,
          cs.standard_concept,
          cs.concept_code,
          cs.valid_start_date,
          cs.valid_end_date,
          NULL
     FROM concept_stage cs
    WHERE cs.concept_id IS NULL;

DROP SEQUENCE v5_concept;
  
COMMIT;

--6 Make sure all records are symmetrical and turn if necessary
INSERT INTO concept_relationship_stage (concept_code_1,
                                        concept_code_2,
                                        vocabulary_id_1,
                                        vocabulary_id_2,
                                        relationship_id,
                                        valid_start_date,
                                        valid_end_date,
                                        invalid_reason)
   SELECT crs.concept_code_2,
          crs.concept_code_1,
          crs.vocabulary_id_2,
          crs.vocabulary_id_1,
          r.reverse_relationship_id,
          crs.valid_start_date,
          crs.valid_end_date,
          crs.invalid_reason
     FROM concept_relationship_stage crs
          JOIN relationship r ON r.relationship_id = crs.relationship_id
    WHERE NOT EXISTS
             (                                           -- the inverse record
              SELECT 1
                FROM concept_relationship_stage i
               WHERE     crs.concept_code_1 = i.concept_code_2
                     AND crs.concept_code_2 = i.concept_code_1
                     AND crs.vocabulary_id_1 = i.vocabulary_id_2
                     AND crs.vocabulary_id_2 = i.vocabulary_id_1
                     AND r.reverse_relationship_id = i.relationship_id);
COMMIT;		

-- 7. Update all relationships existing in concept_relationship_stage, including undeprecation of formerly deprecated ones
MERGE INTO concept_relationship d
    USING (
        with rel_id as (
            SELECT /*+ MATERIALIZE */ DISTINCT c1.concept_id concept_id_1, c2.concept_id concept_id_2, crs.relationship_id, crs.valid_end_date, crs.invalid_reason
            FROM concept_relationship_stage crs, concept c1, concept c2 where
            c1.concept_code = crs.concept_code_1 AND c1.vocabulary_id = crs.vocabulary_id_1
            and c2.concept_code = crs.concept_code_2 AND c2.vocabulary_id = crs.vocabulary_id_2
        )
        SELECT r.rowid rid, rel.valid_end_date, rel.invalid_reason
        FROM concept_relationship r, rel_id rel
        where
        r.concept_id_1=rel.concept_id_1 and r.concept_id_2=rel.concept_id_2 
        and r.relationship_id=rel.relationship_id and r.valid_end_date <> rel.valid_end_date  
    ) o
ON (d.rowid = o.rid)
WHEN MATCHED THEN UPDATE SET d.valid_end_date = o.valid_end_date, d.invalid_reason = o.invalid_reason;

COMMIT; 

-- 8. Deprecate missing relationships, but only if the concepts exist. If relationships are missing because of deprecated concepts, leave them intact.
-- Also, only relationships are considered missing if the combination of vocabulary_id_1, vocabulary_id_2 AND relationship_id is present in concept_relationship_stage
-- The latter will prevent large-scale deprecations of relationships between vocabularies where the relationship is defined not here, but together with that other vocab

-- create a list of vocab1, vocab2 and relationship_id existing in concept_relationship_stage
CREATE TABLE r_coverage NOLOGGING AS
SELECT DISTINCT r1.vocabulary_id||'-'||r2.vocabulary_id||'-'||r.relationship_id as combo
       FROM concept_relationship_stage r
       JOIN concept r1 ON r1.concept_code = r.concept_code_1 AND r1.vocabulary_id = r.vocabulary_id_1
       JOIN concept r2 ON r2.concept_code = r.concept_code_2 AND r2.vocabulary_id = r.vocabulary_id_2
  WHERE r.vocabulary_id_1 not in ('NDC', 'SPL')
  AND r.vocabulary_id_2 not in ('NDC', 'SPL')
  AND r.relationship_id not in (
            'UCUM replaced by',
            'Concept replaced by',
            'Concept same_as to',
            'Concept alt_to to',
            'Concept poss_eq to',
            'Concept was_a to',
            'LOINC replaced by',
            'RxNorm replaced by',
            'SNOMED replaced by',
            'ICD9P replaced by'
      )
;

-- Deprecate sets of concept_relationship that are perceived complete
UPDATE concept_relationship d
   SET valid_end_date =
            (SELECT v.latest_update
                 FROM concept c JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       invalid_reason = 'D'
      -- Whether the combination of vocab1, vocab2 and relationship exists (in r_coverage)
      -- (intended to be covered by this particular vocab udpate)
      -- And both concepts exist (don't deprecate relationships of deprecated concepts)
      WHERE d.rowid in (SELECT d1.rowid
						FROM concept e1, concept e2, concept_relationship d1
						WHERE  e1.concept_id = d1.concept_id_1 AND e2.concept_id = d1.concept_id_2
						AND e1.vocabulary_id||'-'||e2.vocabulary_id||'-'||d1.relationship_id IN (SELECT combo FROM r_coverage)
						AND e1.valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') 
						AND e2.valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') 
	  )
      -- And the record is currently fresh
      AND d.valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') 
       -- And it was started before release date
      AND d.valid_start_date <
                (SELECT latest_update -1 FROM vocabulary v, concept_stage c
                  WHERE     v.vocabulary_id = c.vocabulary_id
                        AND c.concept_id = d.concept_id_1)
       -- AND doesn't exist in the new concept_relationship_stage for all vocabulary_id except 'NDC' and 'SPL'
	   -- OR exist in the new concept_relationship_stage for 'NDC' and 'SPL'
      AND (
			(
				NOT EXISTS (
				  SELECT 1
					 FROM concept_relationship_stage r
					 JOIN concept r1 ON r1.concept_code = r.concept_code_1 AND r1.vocabulary_id = r.vocabulary_id_1
					 JOIN concept r2 ON r2.concept_code = r.concept_code_2 AND r2.vocabulary_id = r.vocabulary_id_2
					WHERE     d.concept_id_1 = r1.concept_id
						  AND d.concept_id_2 = r2.concept_id
						  AND d.relationship_id = r.relationship_id
				) 
       -- Deal with replacing relationships separately, since they can only have one per deprecated concept
;

-- Deprecate concept_relationship records of the kind Replaced by if different one for a given concept exists in concept_relationship_stage
UPDATE concept_relationship d
   SET valid_end_date =
            (SELECT v.latest_update
                 FROM concept c JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       invalid_reason = 'D'
  WHERE d.relationship_id in (
            'UCUM replaced by',
            'Concept replaced by',
            'Concept same_as to',
            'Concept alt_to to',
            'Concept poss_eq to',
            'Concept was_a to',
            'LOINC replaced by',
            'RxNorm replaced by',
            'SNOMED replaced by',
            'ICD9P replaced by'
        )
  AND EXISTS (
    SELECT 1 FROM concept_relationship_stage s 
      WHERE s.concept_id_1 = d.concept_id_1 -- if exists a new one for the concept
      and s.relationship_id = d.relationship_id -- one of the above relationship_id
  )
;

UPDATE concept_relationship d
   SET valid_end_date =
            (SELECT v.latest_update
                 FROM concept c JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       invalid_reason = 'D'
  WHERE d.relationship_id in (
            'LOINC replaces', 
            'RxNorm replaces', 
            'SNOMED replaces',
            'Concept replaces',
            'Concept same_as from',
            'Concept alt_to from',
            'Concept poss_eq from',
            'Concept was_a from',
            'ICD9P replaces',
            'UCUM replaces'
        )
  AND EXISTS (
    SELECT 1 FROM concept_relationship_stage s 
      WHERE s.concept_id_2 = d.concept_id_2 -- if exists a new one for the concept
      and s.relationship_id = d.relationship_id -- one of the above relationship_id
  )
;

COMMIT;

DROP TABLE r_coverage PURGE;

-- 9. INSERT new relationships
ALTER TABLE concept_relationship NOLOGGING;

INSERT /*+ APPEND */ INTO concept_relationship (concept_id_1,
                                  concept_id_2,
                                  relationship_id,
                                  valid_start_date,
                                  valid_end_date,
                                  invalid_reason)
   SELECT DISTINCT 
          r1.concept_id,
          r2.concept_id,
          crs.relationship_id,
          crs.valid_start_date,
          TO_DATE ('20991231', 'YYYYMMDD') AS valid_end_date,
          NULL AS invalid_reason
    FROM concept_relationship_stage crs
    JOIN concept r1 ON r1.concept_code = crs.concept_code_1 AND r1.vocabulary_id = crs.vocabulary_id_1
    JOIN concept r2 ON r2.concept_code = crs.concept_code_2 AND r2.vocabulary_id = crs.vocabulary_id_2
    WHERE NOT EXISTS
             (SELECT 1
                FROM concept_relationship r
               -- test whether concept_ids matched to the concept_codes
               WHERE     r1.concept_id = r.concept_id_1
                     AND r2.concept_id = r.concept_id_2
                     AND crs.relationship_id = r.relationship_id
              )
;
COMMIT;

ALTER TABLE concept_relationship LOGGING;

-- 10. UPDATE invalid_reason
UPDATE concept SET invalid_reason=NULL WHERE valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') AND invalid_reason IS NOT NULL;
COMMIT;

UPDATE concept c SET c.invalid_reason='U' 
WHERE c.valid_end_date <> to_date('31.12.2099','dd.mm.yyyy')
AND EXISTS (
    SELECT 1 FROM concept_relationship r 
    WHERE r.concept_id_1=c.concept_id AND r.relationship_id IN (
            'UCUM replaced by',
            'Concept replaced by',
            'Concept same_as to',
            'Concept alt_to to',
            'Concept poss_eq to',
            'Concept was_a to',
            'LOINC replaced by',
            'RxNorm replaced by',
            'SNOMED replaced by',
            'ICD9P replaced by'
    )
);
COMMIT;

UPDATE concept c SET c.invalid_reason='D'
WHERE c.valid_end_date <> to_date('31.12.2099','dd.mm.yyyy')
AND NOT EXISTS (
    SELECT 1 FROM concept_relationship r 
    WHERE r.concept_id_1=c.concept_id AND r.relationship_id IN (
            'UCUM replaced by',
            'Concept replaced by',
            'Concept same_as to',
            'Concept alt_to to',
            'Concept poss_eq to',
            'Concept was_a to',
            'LOINC replaced by',
            'RxNorm replaced by',
            'SNOMED replaced by',
            'ICD9P replaced by'
    )
);
COMMIT;
 
-- 11. UPDATE concept_synonym
--remove all existing synonyms, except old ones
DELETE FROM concept_synonym csyn
      WHERE csyn.concept_id IN (SELECT c.concept_id
                                  FROM concept c, concept_stage cs
                                 WHERE     C.CONCEPT_CODE = CS.CONCEPT_CODE
                                       AND CS.VOCABULARY_ID = C.VOCABULARY_ID);

--add new synonyms for existing concepts
INSERT /*+ APPEND */ INTO concept_synonym (concept_id,
                             concept_synonym_name,
                             language_concept_id)
   SELECT c.concept_id, synonym_name, 4093769
     FROM concept_synonym_stage css, concept c, concept_stage cs
    WHERE     css.synonym_concept_code = c.concept_code
          AND css.synonym_vocabulary_id = c.vocabulary_id
          AND CS.CONCEPT_CODE = C.CONCEPT_CODE
          AND CS.VOCABULARY_ID = C.VOCABULARY_ID;

COMMIT;

-- Fix mapping to self. The rules are:
-- - concept_id_1 should not be 'C' or null
-- - concept_id_2 should be 'S' (and fresh)