WITH prices AS (
    SELECT
        date_trunc('day', MINUTE) AS DAY,
        contract_address AS token,
        decimals,
        symbol,
        AVG(price) AS price
    FROM
        prices.usd
    WHERE
        MINUTE >= '{{2. Start date}}'
        AND MINUTE <= '{{3. End date}}'
    GROUP BY
        1,
        2,
        3,
        4
),
swaps_changes AS (
    SELECT
        DAY,
        pool,
        token,
        SUM(COALESCE(delta, 0)) AS delta
    FROM
        (
            SELECT
                date_trunc('day', evt_block_time) AS DAY,
                "poolId" AS pool,
                "tokenIn" AS token,
                "amountIn" AS delta
            FROM
                balancer_v2."Vault_evt_Swap"
            UNION
            ALL
            SELECT
                date_trunc('day', evt_block_time) AS DAY,
                "poolId" AS pool,
                "tokenOut" AS token,
                - "amountOut" AS delta
            FROM
                balancer_v2."Vault_evt_Swap"
        ) swaps
    GROUP BY
        1,
        2,
        3
),
internal_changes AS (
    SELECT
        date_trunc('day', evt_block_time) AS DAY,
        '\xBA12222222228d8Ba445958a75a0704d566BF2C8' :: bytea AS pool,
        token,
        SUM(COALESCE(delta, 0)) AS delta
    FROM
        balancer_v2."Vault_evt_InternalBalanceChanged"
    GROUP BY
        1,
        2,
        3
),
balances_changes AS (
    SELECT
        date_trunc('day', evt_block_time) AS DAY,
        "poolId" AS pool,
        UNNEST(tokens) AS token,
        UNNEST(deltas) AS delta
    FROM
        balancer_v2."Vault_evt_PoolBalanceChanged"
),
managed_changes AS (
    SELECT
        date_trunc('day', evt_block_time) AS DAY,
        "poolId" AS pool,
        token,
        "managedDelta" AS delta
    FROM
        balancer_v2."Vault_evt_PoolBalanceManaged"
),
daily_delta_balance AS (
    SELECT
        DAY,
        pool,
        token,
        SUM(COALESCE(amount, 0)) AS amount
    FROM
        (
            SELECT
                DAY,
                pool,
                token,
                SUM(COALESCE(delta, 0)) AS amount
            FROM
                balances_changes
            GROUP BY
                1,
                2,
                3
            UNION
            ALL
            SELECT
                DAY,
                pool,
                token,
                delta AS amount
            FROM
                swaps_changes
            UNION
            ALL
            SELECT
                DAY,
                pool,
                token,
                delta AS amount
            FROM
                internal_changes
            UNION
            ALL
            SELECT
                DAY,
                pool,
                token,
                delta AS amount
            FROM
                managed_changes
        ) balance
    WHERE
        DAY <= '{{3. End date}}'
    GROUP BY
        1,
        2,
        3
),
cumulative_balance AS (
    SELECT
        DAY,
        pool,
        token,
        LEAD(DAY, 1, NOW()) OVER (
            PARTITION BY token,
            pool
            ORDER BY
                DAY
        ) AS day_of_next_change,
        SUM(amount) OVER (
            PARTITION BY pool,
            token
            ORDER BY
                DAY ROWS BETWEEN UNBOUNDED PRECEDING
                AND CURRENT ROW
        ) AS cumulative_amount
    FROM
        daily_delta_balance
),
weekly_delta_balance_by_token AS (
    SELECT
        DAY,
        pool,
        token,
        cumulative_amount,
        (
            cumulative_amount - COALESCE(
                LAG(cumulative_amount, 1) OVER (
                    PARTITION BY pool,
                    token
                    ORDER BY
                        DAY
                ),
                0
            )
        ) AS amount
    FROM
        (
            SELECT
                DAY,
                pool,
                token,
                SUM(cumulative_amount) AS cumulative_amount
            FROM
                cumulative_balance b
            WHERE
                extract(
                    dow
                    FROM
                        DAY
                ) = 1
            GROUP BY
                1,
                2,
                3
        ) foo
),
calendar AS (
    SELECT
        generate_series(
            '2021-07-01' :: timestamp,
            CURRENT_DATE,
            '1 day' :: INTERVAL
        ) AS DAY
),
cumulative_usd_balance AS (
    SELECT
        c.day,
        b.pool,
        b.token,
        symbol,
        cumulative_amount,
        (p1.price * cumulative_amount / 10 ^ p1.decimals) AS amount_usd_from_api,
        0 AS amount_usd_from_dex
    FROM
        calendar c
        LEFT JOIN cumulative_balance b ON b.day <= c.day
        AND c.day < b.day_of_next_change
        LEFT JOIN prices p1 ON p1.day = c.day
        AND p1.token = b.token
),
estimated_token_liquidity AS (
    SELECT
        DAY,
        token,
        symbol,
        SUM(
            COALESCE(amount_usd_from_api, amount_usd_from_dex)
        ) AS liquidity
    FROM
        cumulative_usd_balance
    GROUP BY
        1,
        2,
        3
),
tvl AS (
    SELECT
        DAY,
        token,
        symbol,
        SUM(liquidity) AS tvl
    FROM
        estimated_token_liquidity
    GROUP BY
        1,
        2,
        3
),
total_tvl AS (
    SELECT
        DAY,
        'Total' AS token,
        SUM(tvl) AS tvl
    FROM
        tvl
    GROUP BY
        1,
        2
),
top_tokens AS (
    SELECT
        DISTINCT token,
        symbol,
        tvl
    FROM
        tvl t
    WHERE
        DAY = CURRENT_DATE
        AND tvl IS NOT NULL
    ORDER BY
        3 DESC
    LIMIT
        5
)
SELECT
    *
FROM
    total_tvl
WHERE
    DAY >= '{{2. Start date}}'
    AND DAY <= '{{3. End date}}'
UNION
ALL
SELECT
    t.day,
    COALESCE(p.symbol, 'Others') AS token,
    SUM(t.tvl) AS "TVL"
FROM
    tvl t
    LEFT JOIN top_tokens p ON p.token = t.token
WHERE
    DAY >= '{{2. Start date}}'
    AND DAY <= '{{3. End date}}'
GROUP BY
    1,
    2
ORDER BY
    1