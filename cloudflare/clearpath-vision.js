const allowedOrigin = 'https://kingjose05.github.io';

const corsHeaders = {
  'Access-Control-Allow-Origin': allowedOrigin,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json; charset=UTF-8',
};

const statementSchema = {
  type: 'object',
  additionalProperties: false,
  required: [
    'bankName', 'lastFour', 'accountType', 'availableBalanceDop',
    'availableBalanceUsd', 'currentTotalDop', 'statementBalanceDop',
    'minimumDueDop', 'statementBalanceUsd', 'minimumDueUsd',
    'installmentBalance', 'installmentMonthlyPayment', 'cutoffDate',
    'dueDate', 'rawText',
  ],
  properties: {
    bankName: { type: 'string' },
    lastFour: { type: 'string' },
    accountType: { type: 'string', enum: ['credit', 'debit'] },
    availableBalanceDop: { type: ['number', 'null'] },
    availableBalanceUsd: { type: ['number', 'null'] },
    currentTotalDop: { type: ['number', 'null'] },
    statementBalanceDop: { type: ['number', 'null'] },
    minimumDueDop: { type: ['number', 'null'] },
    statementBalanceUsd: { type: ['number', 'null'] },
    minimumDueUsd: { type: ['number', 'null'] },
    installmentBalance: { type: ['number', 'null'] },
    installmentMonthlyPayment: { type: ['number', 'null'] },
    cutoffDate: { type: ['string', 'null'] },
    dueDate: { type: ['string', 'null'] },
    rawText: { type: 'string' },
  },
};

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
    if (request.method !== 'POST') return reply({ error: 'Use POST.' }, 405);
    if (request.headers.get('Origin') !== allowedOrigin) {
      return reply({ error: 'This endpoint only accepts ClearPath requests.' }, 403);
    }
    if (!env.OPENAI_API_KEY) return reply({ error: 'Missing API configuration.' }, 500);

    let body;
    try {
      body = await request.json();
    } catch (_) {
      return reply({ error: 'Invalid request body.' }, 400);
    }
    if (typeof body.image !== 'string' || !body.image.startsWith('data:image/')) {
      return reply({ error: 'An image is required.' }, 400);
    }
    if (body.image.length > 9_000_000) return reply({ error: 'Image is too large.' }, 413);

    const openai = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'gpt-5-mini',
        input: [{
          role: 'user',
          content: [
            {
              type: 'input_text',
              text: 'Read this Dominican Republic bank account or card screenshot exactly. Extract only values visibly present. Do not invent values. Treat cuotas/installments separately from revolving credit. For debit or savings/checking accounts use accountType debit; otherwise credit. All DOP and USD amounts are positive numbers without currency symbols. Dates must be YYYY-MM-DD when a full date is shown, otherwise null. rawText should concisely transcribe the relevant labels and values.',
            },
            { type: 'input_image', image_url: body.image, detail: 'high' },
          ],
        }],
        text: {
          format: {
            type: 'json_schema',
            name: 'bank_statement',
            strict: true,
            schema: statementSchema,
          },
        },
      }),
    });

    const result = await openai.json();
    if (!openai.ok) return reply({ error: result.error?.message || 'Vision analysis failed.' }, openai.status);
    try {
      return reply({ statement: JSON.parse(result.output_text) });
    } catch (_) {
      return reply({ error: 'Vision response was not valid statement data.' }, 502);
    }
  },
};

function reply(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: corsHeaders });
}
