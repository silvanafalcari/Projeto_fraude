/* =====================================================================
   ANÁLISE DE FRAUDE EM TRANSAÇÕES — construção da tabela de modelagem
   Base: abt_fraude (150.000 linhas × 20 colunas), grão = 1 transação
   Dialeto: BigQuery (GoogleSQL / Standard SQL)
   ===================================================================== */
/* ---------------------------------------------------------------------
   0) CONSTRUÇÃO DA TABELA DE MODELAGEM (abt_fraude)
   Une as 4 tabelas no grão de transação e remove registros de teste.
   As dimensões (dim_paises, dim_categorias) não entram aqui — são usadas
   apenas para enriquecer a análise.
  ---------------------------------------------------------------------*/

CREATE TABLE `poscientistadados1.fraude.abt_fraude` AS (
SELECT sc.score_1, 
       sc.score_2, 
       sf.score_3, 
       sc.score_4, 
       sc.score_5, 
       sf.score_6, 
       t.pais, 
       sc.score_7, 
       t.produto, 
       t.categoria_produto, 
       sm.score_8, 
       sf.score_9, 
       sf.score_10, 
       t.entrega_doc_1, 
       t.entrega_doc_2, 
       t.entrega_doc_3, 
       t.data_compra, 
       t.valor_compra, 
       sm.score_fraude_modelo, 
       sm.fraude
FROM `poscientistadados1.fraude.transacoes` AS t
INNER JOIN `poscientistadados1.fraude.scores_comportamentais` AS sc
ON t.id_transacao = sc.id_transacao
INNER JOIN `poscientistadados1.fraude.scores_financeiros` AS sf
ON t.id_transacao = sf.id_transacao
INNER JOIN `poscientistadados1.fraude.scores_modelo` AS sm
ON t.id_transacao = sm.id_transacao
WHERE t.is_teste = 0);


-- Conferências de aceite
SELECT COUNT(*)                    AS linhas          FROM `poscientistadados1.fraude.abt_fraude`;  -- 150.000
SELECT ROUND(100.0*AVG(fraude), 3) AS taxa_fraude_pct FROM `poscientistadados1.fraude.abt_fraude`;  -- 5%

