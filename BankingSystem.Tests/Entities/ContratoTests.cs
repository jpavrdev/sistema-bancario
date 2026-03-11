using BankingSystem.Domain.Entities;

namespace BankingSystem.Tests.Entities;

public class ContratosTests
{
    [Fact]
    public void Criar_ComUsuarioIdVazio_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Contrato.Criar(
                Guid.Empty,
                "Descrição",
                100,
                0,
                0
            )
        );
    }

    [Fact]
    public void Criar_ComDescricaoVazia_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Contrato.Criar(
                Guid.NewGuid(),
                "",
                15000,
                0,
                0
            )
        );
    }

    [Fact]
    public void Criar_ComValorTotalFinanciadoIgualZero_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Contrato.Criar(
                Guid.NewGuid(),
                "Descrição",
                0,
                0,
                0
            )
        );
    }

    [Fact]
    public void Criar_ComValorTotalFinanciadoNegativo_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Contrato.Criar(
                Guid.NewGuid(),
                "Descrição",
                -100,
                0,
                0
            )
        );
    }

    [Fact]
    public void Criar_ComTaxaJurosMensalNegativa_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Contrato.Criar(
                Guid.NewGuid(),
                "Descrição",
                100,
                -100,
                0
            )
        );
    }

    [Fact]
    public void Criar_ComTaxaMultaAtrasoNegativa_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Contrato.Criar(
                Guid.NewGuid(),
                "Descrição",
                100,
                0,
                -100
            )
        );
    }

    [Fact]
    public void Criar_ComDadosValidos_DeveRetornarContrato()
    {
        var contrato = Contrato.Criar(
            Guid.NewGuid(),
            "Descrição",
            100,
            0,
            0
        );
        Assert.NotNull(contrato);
        Assert.Equal("Descrição", contrato.Descricao);
        Assert.Equal(100, contrato.ValorTotalFinanciado);
        Assert.Equal(0, contrato.TaxaJurosMensal);
        Assert.Equal(0, contrato.TaxaMultaAtraso);
    }
}
