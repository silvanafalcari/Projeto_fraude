/* =====================================================================
   ANÁLISE DE FRAUDE EM TRANSAÇÕES — queries analíticas
   Base: abt_fraude (150.000 linhas × 20 colunas), grão = 1 transação
   Dialeto: BigQuery (GoogleSQL / Standard SQL)
   Notas de portabilidade ao final do arquivo.
   ===================================================================== */

/* ---------------------------------------------------------------------
   1) PANORAMA — tamanho do problema
   
     Calcular: o número total de transações 
               a quantidade de fraudes 
               a taxa percentual de fraude 
               o valor monetário exposto 
               o ticket medio fraude
               o ticket médio geral
     AVG(fraude) funciona como taxa porque fraude é 0/1.
   --------------------------------------------------------------------- */

SELECT
    COUNT(*)                                                          AS total,
    SUM(fraude)                                                       AS fraudes,
    ROUND(100.0*AVG(fraude), 3)                                       AS taxa_fraude_pct,
    ROUND(SUM(CASE WHEN fraude = 1 THEN valor_compra ELSE 0 END), 2)  AS valor_exposto,
    ROUND(AVG(CASE WHEN fraude = 1 THEN valor_compra END), 2)         AS ticket_medio_fraude,
    ROUND(AVG(valor_compra), 2)                                       AS ticket_medio_geral
FROM `poscientistadados1.fraude.abt_fraude`;

-- Resultado: 150000 | 7500 | 5.000% | R$547.271,12 | R$72,97 | R$43,52

/* ---------------------------------------------------------------------
   2) FRAUDE POR PAÍS  (JOIN com dimensão + piso de volume)
   O HAVING descarta praças pequenas demais para uma taxa confiável.
   --------------------------------------------------------------------- */
SELECT
    p.nome_pais,
    p.regiao,
    COUNT(*)                       AS transacoes,
    ROUND(100.0*AVG(a.fraude), 2)  AS taxa_fraude_pct
FROM `poscientistadados1.fraude.abt_fraude` AS a
INNER JOIN `poscientistadados1.fraude.dim_paises` AS p 
ON p.sigla_pais = a.pais
GROUP BY p.nome_pais, p.regiao
HAVING COUNT(*) >= 1000
ORDER BY taxa_fraude_pct DESC;

-- BR 5,52% (111.628) | AR 3,69% (31.964) | US 3,08% (2.273) | UY 0,98% (2.967)

/* ---------------------------------------------------------------------
   3) RISCO CADASTRADO vs. REALIDADE  (JOIN com dim_categorias)
   Confronta o nivel_risco_categoria pré-cadastrado com a taxa observada.
   --------------------------------------------------------------------- */
SELECT
    c.nivel_risco_categoria,
    COUNT(*)                       AS transacoes,
    ROUND(100.0*AVG(a.fraude), 2)  AS taxa_fraude_pct
FROM `poscientistadados1.fraude.abt_fraude` AS a
INNER JOIN `poscientistadados1.fraude.dim_categorias` AS c 
ON c.id_categoria = a.categoria_produto
GROUP BY c.nivel_risco_categoria
ORDER BY taxa_fraude_pct DESC;

--medio    47079  5.21 / alto 53379  5.06  /  baixo   49542  4.74

/* ---------------------------------------------------------------------
   4) FRAUDE POR FAIXA DE VALOR  (CASE WHEN)
   Transforma o valor contínuo em faixas comparáveis.
   --------------------------------------------------------------------- */

WITH base AS (
  SELECT
    CASE
      WHEN valor_compra < 100 THEN '1) ate 100'
      WHEN valor_compra < 500 THEN '2) 100-500'
      WHEN valor_compra >= 500 THEN '3) acima de 500'
      ELSE                          '4) valor NULL'   -- separa nulos em vez de escondê-los na faixa 3
    END AS faixa_valor,
    fraude,
    valor_compra
  FROM `poscientistadados1.fraude.abt_fraude`
)

SELECT
  faixa_valor,
  COUNT(*)     AS transacoes,
  SUM(fraude)  AS fraudes,
  ROUND(100.0 * SUM(fraude) / COUNT(*),2) AS taxa_fraude_pct,
  ROUND(100.0 * SUM(fraude) / SUM(SUM(fraude)) OVER (), 1) AS pct_dos_casos, ---- das fraudes daquela faixa sobre o total de fraudes
  ROUND(SUM(CASE WHEN fraude = 1 THEN valor_compra ELSE 0 END), 2) AS valor_exposto,
  ROUND(100.0 * SUM(CASE WHEN fraude = 1 THEN valor_compra ELSE 0 END)
        / SUM(SUM(CASE WHEN fraude = 1 THEN valor_compra ELSE 0 END)) OVER (), 1)   AS pct_do_valor,
  ROUND(SAFE_DIVIDE(
          SUM(CASE WHEN fraude = 1 THEN valor_compra ELSE 0 END),
          SUM(fraude)
        ), 2)   AS perda_media_por_fraude
FROM base
GROUP BY faixa_valor
ORDER BY faixa_valor;

/* -------resultado da query --------------------------------------------------------------
faixa_valor	transacoes	fraudes	taxa_fraude_pct	pct_dos_casos	valor_exposto	pct_do_valor	perda_media_por_fraude
1) ate 100	137284	6313	4.6	84.2	169628.21	31	26.87
2) 100-500	11679	1032	8.84	13.8	233386.93	42.6	226.15
3) acima de 500	1037	155	14.95	2.1	144255.98	26.4	930.68
 --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   5) O SCORE DO MODELO SEPARA FRAUDE?  (NTILE — função de janela)
   Divide a base em 10 faixas iguais por score e mede a taxa em cada uma.
   Espera-se que a taxa cresça de forma consistente do decil 1 ao 10.
   --------------------------------------------------------------------- */
WITH faixas AS (
    SELECT
        fraude,
        NTILE(10) OVER (ORDER BY score_fraude_modelo) AS decil
    FROM `poscientistadados1.fraude.abt_fraude`
)
SELECT
    decil,
    COUNT(*)                     AS transacoes,
    ROUND(100.0*AVG(fraude), 2)  AS taxa_fraude_pct
FROM faixas
GROUP BY decil
ORDER BY decil;

/* ----------------------resultado da query
-- 1: 2,79  2: 4,62  3: 3,27  4: 0,3  5: 0.59  6: 1,31  7: 1,99  8: 5,18  9: 8,64  10: 21,31
-- Leitura: separa bem só no topo (decil 10 ~= 4x a base); o meio nao e monotonico.

/* ---------------------------------------------------------------------
   6) CURVA DE CAPTURA ACUMULADA
   Ordenando a fila do maior score para o menor, quanto da fraude total
   é capturada ao revisar os X% de maior risco?
   --------------------------------------------------------------------- */

WITH faixas AS (
    SELECT
        fraude,
        NTILE(10) OVER (ORDER BY score_fraude_modelo) AS decil
    FROM `poscientistadados1.fraude.abt_fraude`
)
SELECT
    decil,
    COUNT(*)                     AS transacoes,
    ROUND(100.0*AVG(fraude), 2)  AS taxa_fraude_pct
FROM faixas
GROUP BY decil
ORDER BY decil;

-- query analitica6
WITH faixas AS (
    SELECT
        fraude,
        NTILE(10) OVER (ORDER BY score_fraude_modelo DESC) AS decil_desc
    FROM `poscientistadados1.fraude.abt_fraude`
),
por_decil AS (
    SELECT decil_desc, SUM(fraude) AS fraudes
    FROM faixas
    GROUP BY decil_desc
)
SELECT
    decil_desc                                                        AS decil_top,
    10 * decil_desc                                                   AS pct_fila_revisada,
    SUM(fraudes) OVER (ORDER BY decil_desc)                           AS fraudes_acumuladas,
    ROUND(100.0 * SUM(fraudes) OVER (ORDER BY decil_desc)
                / SUM(fraudes) OVER (), 1)                            AS pct_fraude_capturada
    
FROM por_decil
ORDER BY decil_desc;

/* ----- resultado da query
 10% da fila -> 42,9% da fraude | 20% -> 59,9% | 30% -> 70,3% | 50% -> 76,8% | 100% -> 100%
decil_top pct_fila_revisada fraudes_acumuladas	pct_fraude_capturada
1	   10	             3214	                        42.9
2	   20	             4494	                        59.9
3	   30	             5271	                        70.3
4	   40	             5568	                        74.2
5	   50	             5761	                        76.8
6	   60	             5850	                        78
7	   70	             5897	                        78.6
8	   80	             6389	                        85.2
9	   90	             7084	                        94.5
10	   100	             7500	                        100
******************************************/


/* ---------------------------------------------------------------------
   7) BÔNUS — FRAUDE POR MÊS  (série temporal)
   No BigQuery, DATE_TRUNC recebe a data primeiro e o intervalo como
   palavra-chave (MONTH), diferente do PostgreSQL.
   --------------------------------------------------------------------- */
SELECT
    DATE_TRUNC(data_compra, MONTH)  AS mes,
    COUNT(*)                        AS transacoes,
     SUM(fraude)                    AS fraudes,
    ROUND(100.0*AVG(fraude), 2)     AS taxa_fraude_pct
FROM `poscientistadados1.fraude.abt_fraude`
GROUP BY mes
ORDER BY mes;

/* ---- resultado ------
mes          transacoes  fraudes   taxa_fraude_pct
2020-03-01    76961       3877       5.04
2020-04-01    73039       3623       4.96


