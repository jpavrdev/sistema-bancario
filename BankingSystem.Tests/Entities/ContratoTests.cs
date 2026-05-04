using BankingSystem.Domain.Entities;
using BankingSystem.Domain.Common;
using Microsoft.Extensions.Time.Testing;

namespace BankingSystem.Tests.Entities;

public class ContratosTests
{
    [Fact]
    public void Criar_ComUsuarioIdVazio_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();

        var result = Contrato.Criar(Guid.Empty, "Descrição", 100, 0, 0, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("UsuarioId é obrigatório.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComDescricaoVazia_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        var result = Contrato.Criar(Guid.NewGuid(), "", 0, 0, 0, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Descrição é obrigatória.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComValorTotalFinanciadoIgualZero_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        var result = Contrato.Criar(Guid.NewGuid(), "Descrição", 0, 0, 0, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Valor Total Financiado deve ser maior que zero.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComValorTotalFinanciadoNegativo_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        var result = Contrato.Criar(Guid.NewGuid(), "Descrição", -100, 0, 0, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Valor Total Financiado deve ser maior que zero.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComTaxaJurosMensalNegativa_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        var result = Contrato.Criar(Guid.NewGuid(), "Descrição", 100, -100, 0, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Taxa de Juros Mensal não pode ser negativa.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComTaxaMultaAtrasoNegativa_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        var result = Contrato.Criar(Guid.NewGuid(), "Descrição", 100, 0, -100, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Taxa de multa não pode ser negativa.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComDadosValidos_DeveRetornarContrato()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        var result = Contrato.Criar(Guid.NewGuid(), "Descrição", 100, 0, 0, fakeTimeProvider);
        Assert.True(result.IsSuccess);
        Assert.Equal("Descrição", result.Value!.Descricao);
        Assert.Equal(100, result.Value!.ValorTotalFinanciado);
        Assert.Equal(0, result.Value!.TaxaJurosMensal);
        Assert.Equal(0, result.Value!.TaxaMultaAtraso);
    }
}
