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
    'bankName', 'accountName', 'lastFour', 'accountType', 'availableBalanceDop',
    'availableBalanceUsd', 'currentTotalDop', 'statementBalanceDop',
    'currentTotalUsd', 'minimumDueDop', 'statementBalanceUsd', 'minimumDueUsd',
    'installmentBalance', 'installmentMonthlyPayment', 'cutoffDate',
    'dueDate', 'rawText',
  ],
  properties: {
    bankName: { type: 'string' },
    accountName: { type: 'string' },
    lastFour: { type: 'string' },
    accountType: { type: 'string', enum: ['credit', 'debit'] },
    availableBalanceDop: { type: ['number', 'null'] },
    availableBalanceUsd: { type: ['number', 'null'] },
    currentTotalDop: { type: ['number', 'null'] },
    currentTotalUsd: { type: ['number', 'null'] },
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
              text: 'Read this Dominican Republic bank account or card screenshot exactly. Extract only visibly present values; do not infer or invent. bankName is the bank (for example APAP, BHD, Banco Popular); accountName is the visible product/card name plus last four when available. For debit, savings, or checking accounts use accountType debit; otherwise credit. Map "Saldo a la fecha", "Balance a la fecha", "Balance total", or "Total adeudado" to currentTotal in its correct currency. Map "Balance al corte" or "Saldo al corte" only to statementBalance. Map "Pago minimo" only to minimumDue. Map "Disponible" or "Balance disponible" only to availableBalance. Never put a credit limit or available credit into a debt field. Keep DOP and USD values separate. Treat cuotas/installments separately: installmentMonthlyPayment is only a monthly cuota/monto cuota; installmentBalance is only an explicitly stated total outstanding cuotas balance. If the screenshot gives only a monthly cuota, leave installmentBalance null. Dates must be YYYY-MM-DD only when a full date is shown; otherwise null. All amounts are positive numbers without currency symbols. rawText should concisely transcribe the relevant labels and values.',
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
