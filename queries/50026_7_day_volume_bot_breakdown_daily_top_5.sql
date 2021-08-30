-- Volume (source breakdown) per day (last 7 days)
-- Visualization: bar chart (stacked)

WITH prices AS (
        SELECT date_trunc('day', minute) AS day, contract_address AS token, decimals, AVG(price) AS price
        FROM prices.usd
        WHERE date_trunc('day', minute) > date_trunc('day', now() - interval '1 week')
        GROUP BY 1, 2, 3
    ),
    
    swaps AS (
        SELECT date_trunc('day', d.block_time) AS day,
            tx_to AS channel,
            COUNT(*) AS txns,
            sum(usd_amount) AS volume
        FROM dex.trades d
        WHERE project = 'Balancer'
        AND date_trunc('day', d.block_time) > now() - interval '1 week'
        AND ('{{4. Version}}' = 'Both' OR version = SUBSTRING('{{4. Version}}', 2))
        GROUP BY 1, 2
    ),
    
       manual_labels AS (
        SELECT
            address,  
            name
        FROM labels.labels
        WHERE "type" = 'balancer_source'
        AND "author" = 'balancerlabs'
    ),
    
    arb_bots AS (
        SELECT
            address,  
            name
        FROM labels.labels
        WHERE "name" = 'arbitrage bot'
        AND "author" = 'balancerlabs'
        AND address NOT IN (SELECT address from manual_labels)
    ),
    
    distinct_labels AS (
        SELECT * FROM manual_labels
        union all
        SELECT * FROM arb_bots
    ),
    
    channels AS (
        SELECT channel, sum(coalesce(volume,00)) as volume from swaps group by 1
    ),
    
    trade_count AS (
        SELECT
            date_trunc('day', block_time) AS day,
            tx_to AS channel,
            COUNT(1) AS daily_trades
        FROM dex.trades
        WHERE trader_a != '\x0000000000000000000000000000000000000000'
        AND project = 'Balancer'
        GROUP BY 1,2
        ),
        
    heavy_traders AS (
        SELECT
            channel, day, daily_trades
        FROM trade_count
        WHERE daily_trades >= 100
        ),
    
    channel_classifier AS (
        SELECT c.channel, l.name,
            CASE WHEN l.name IS NOT NULL THEN l.name
            WHEN f.pool IS NOT NULL THEN 'BPool direct'
            WHEN c.channel IN (SELECT channel FROM heavy_traders) THEN 'heavy trader'
            WHEN c.channel IN (select channel from channels where volume is not null order by volume desc limit 10) THEN CONCAT(SUBSTRING(concat('0x', encode(c.channel, 'hex')), 0, 13), '...')
            ELSE 'others' END AS class
        FROM channels c
        LEFT JOIN balancer."BFactory_evt_LOG_NEW_POOL" f ON f.pool = c.channel
        LEFT JOIN distinct_labels l ON l.address = c.channel
    )
    
SELECT * FROM (
    SELECT
        day,
        s.channel AS "Address",
        CONCAT('<a target="_blank" href="https://etherscan.io/address/0', SUBSTRING(s.channel::text, 2, 42), '">', 'https://etherscan.io/address/0', SUBSTRING(s.channel::text, 2, 42), '</a>') AS etherscan,
        s.txns AS trades,
        sum(volume) AS "Volume",
        ROW_NUMBER() OVER (PARTITION BY day ORDER BY sum(volume) DESC NULLS LAST) AS position
    FROM swaps s 
    INNER JOIN channel_classifier c ON s.channel = c.channel
    WHERE c.class = 'arbitrage bot'
    GROUP BY 1, 2, 3, 4
    ORDER BY day DESC, "Volume" DESC
) ranking
WHERE position <= 5