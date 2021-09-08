WITH lbp_info AS (
    SELECT
        *
    FROM
        balancer.view_lbps
    WHERE
        name = '{{LBP}}'
),
addresses AS (
    SELECT
        "to" AS adr
    FROM
        erc20."ERC20_evt_Transfer" tr
        INNER JOIN lbp_info l ON l.token_sold = tr.contract_address
),
transfers AS (
    SELECT
        DAY,
        address,
        token_address,
        SUM(amount) AS amount
    FROM
        (
            SELECT
                date_trunc('hour', evt_block_time) AS DAY,
                "to" AS address,
                tr.contract_address AS token_address,
                value AS amount
            FROM
                erc20."ERC20_evt_Transfer" tr
                INNER JOIN lbp_info l ON l.token_sold = tr.contract_address
            UNION
            ALL
            SELECT
                date_trunc('hour', evt_block_time) AS DAY,
                "from" AS address,
                tr.contract_address AS token_address,
                - value AS amount
            FROM
                erc20."ERC20_evt_Transfer" tr
                INNER JOIN lbp_info l ON l.token_sold = tr.contract_address
        ) t
    GROUP BY
        1,
        2,
        3
),
balances_with_gap_days AS (
    SELECT
        t.day,
        address,
        token_address,
        SUM(amount) OVER (
            PARTITION BY address
            ORDER BY
                t.day
        ) AS balance,
        LEAD(DAY, 1, NOW()) OVER (
            PARTITION BY address
            ORDER BY
                t.day
        ) AS next_day
    FROM
        transfers t
),
days AS (
    SELECT
        generate_series(
            '2020-01-01' :: timestamp,
            date_trunc('day', NOW()),
            '1 hour'
        ) AS DAY
),
balance_all_days AS (
    SELECT
        d.day,
        address,
        token_address,
        SUM(balance / 10 ^ 0) AS balance
    FROM
        balances_with_gap_days b
        INNER JOIN days d ON b.day <= d.day
        AND d.day < b.next_day
    GROUP BY
        1,
        2,
        3
    ORDER BY
        1,
        2
)
SELECT
    b.day,
    l.token_symbol,
    COUNT(DISTINCT address) AS holders
FROM
    balance_all_days b
    INNER JOIN lbp_info l ON l.token_sold = b.token_address
WHERE
    balance > 0
    AND b.day BETWEEN l.initial_time
    AND l.final_time
GROUP BY
    1,
    2