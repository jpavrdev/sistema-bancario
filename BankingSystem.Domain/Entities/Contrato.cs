using BankingSystem.Domain.Enums;
using BankingSystem.Domain.Common;

namespace BankingSystem.Domain.Entities;

public sealed class Contrato
{
    private readonly List<Parcela> _parcelas = [];
    public IReadOnlyCollection<Parcela> Parcelas => _parcelas.AsReadOnly();

    public Result AdicionarParcela(
        int numeroParcela,
        decimal valorPrincipal,
        decimal saldoDevedor,
        DateTimeOffset dataVencimento,
        TimeProvider timeProvider
    )
    {
        if (_parcelas.Any(p => p.NumeroParcela == numeroParcela))
            return new Error("ParcelaDuplicada", ErrorType.Validation,
                $"Parcela {numeroParcela} já existe neste contrato.");
        var parcela = Parcela.Criar(Id, numeroParcela, valorPrincipal, saldoDevedor, timeProvider, dataVencimento);

        if (!parcela.IsSuccess)
            return parcela.Error!;

        _parcelas.Add(parcela.Value!);

        Versao++;

        return Result.Success();
    }

    public Guid Id { get; private set; }
    public Guid UsuarioId { get; private set; }
    public string Descricao { get; private set; } = null!;
    public decimal ValorTotalFinanciado { get; private set; }
    public decimal TaxaJurosMensal { get; private set; }
    public decimal TaxaMultaAtraso { get; private set; }
    public StatusContrato Status { get; private set; }
    public int Versao { get; private set; }
    public DateTimeOffset DataAssinatura { get; private set; }
    public DateTimeOffset CriadoEm { get; private set; }

    private Contrato() { }

    public static Result<Contrato> Criar(
        Guid usuarioId,
        string descricao,
        decimal valorTotalFinanciado,
        decimal taxaJurosMensal,
        decimal taxaMultaAtraso,
        TimeProvider timeProvider
    )
    {
        if (usuarioId == Guid.Empty)
            return new Error("ContratoInvalido", ErrorType.Validation, "UsuarioId é obrigatório.");

        if (string.IsNullOrWhiteSpace(descricao))
            return new Error("ContratoInvalido", ErrorType.Validation, "Descrição é obrigatória.");

        if (valorTotalFinanciado <= 0)
            return new Error("ContratoInvalido", ErrorType.Validation, "Valor Total Financiado deve ser maior que zero.");

        if (taxaJurosMensal < 0)
            return new Error("ContratoInvalido", ErrorType.Validation, "Taxa de Juros Mensal não pode ser negativa.");

        if (taxaMultaAtraso < 0)
            return new Error("ContratoInvalido", ErrorType.Validation, "Taxa de multa não pode ser negativa.");

        var dataAgora = timeProvider.GetUtcNow();

        return new Contrato
        {
            Id = Guid.NewGuid(),
            UsuarioId = usuarioId,
            Descricao = descricao,
            ValorTotalFinanciado = valorTotalFinanciado,
            TaxaJurosMensal = taxaJurosMensal,
            TaxaMultaAtraso = taxaMultaAtraso,
            DataAssinatura = dataAgora,
            CriadoEm = dataAgora,
            Versao = 1,
        };
    }
}
