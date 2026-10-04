sub Init()
  m.hero = m.top.findNode("hero")
  m.carousel = m.top.findNode("carousel")
  m.top.ObserveField("heroItem", "OnHeroItem")
  m.top.ObserveField("carouselItems", "OnCarouselItems")
end sub

sub OnHeroItem()
  m.hero.itemContent = m.top.heroItem
end sub

sub OnCarouselItems()
  m.carousel.items = m.top.carouselItems
end sub
