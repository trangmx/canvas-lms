/*
 * Copyright (C) 2021 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import React from 'react'
import PropTypes from 'prop-types'
import {View} from '@instructure/ui-view'
import {Flex} from '@instructure/ui-flex'
import {Text} from '@instructure/ui-text'
import {Heading} from '@instructure/ui-heading'
import {Button} from '@instructure/ui-buttons'
import {Spinner} from '@instructure/ui-spinner'
import {TruncateText} from '@instructure/ui-truncate-text'
import I18n from 'i18n!OutcomeManagement'
import FindOutcomeItem from './FindOutcomeItem'
import OutcomeSearchBar from './Management/OutcomeSearchBar'
import InfiniteScroll from '@canvas/infinite-scroll'
import {addZeroWidthSpace} from '@canvas/outcomes/addZeroWidthSpace'

const FindOutcomesView = ({
  collection,
  outcomesCount,
  outcomes,
  loading,
  loadMore,
  searchString,
  onChangeHandler,
  onClearHandler,
  onAddAllHandler
}) => {
  const groupTitle = collection?.name || I18n.t('Outcome Group')
  const enabled = !!outcomesCount && outcomesCount > 0

  const onSelectOutcomesHandler = _id => {
    // TODO: OUT-4154
  }

  if (loading && !outcomes) {
    return (
      <View as="div" padding="xx-large 0" textAlign="center" margin="0 auto" data-testid="loading">
        <Spinner renderTitle={I18n.t('Loading')} size="large" />
      </View>
    )
  }

  return (
    <View
      as="div"
      height="100%"
      minWidth="300px"
      padding="0 x-large 0 medium"
      data-testid="find-outcome-container"
    >
      <div style={{height: '100%', display: 'flex', flexDirection: 'column'}}>
        <View as="div" padding="0 0 x-small" borderWidth="0 0 small">
          <View as="div" padding="small 0 0">
            <Heading level="h2" as="h3">
              <Text wrap="break-word">{addZeroWidthSpace(groupTitle)}</Text>
            </Heading>
          </View>
          <View as="div" padding="large 0 medium">
            <OutcomeSearchBar
              enabled={enabled || searchString.length > 0}
              placeholder={I18n.t('Search within %{groupTitle}', {groupTitle})}
              searchString={searchString}
              onChangeHandler={onChangeHandler}
              onClearHandler={onClearHandler}
            />
          </View>
          <View as="div" position="relative" padding="0 0 small">
            <Flex as="div" alignItems="center" justifyItems="space-between" wrap="wrap">
              <Flex.Item size="50%" padding="0 small 0 0" shouldGrow>
                <Heading level="h4">
                  {searchString ? (
                    <TruncateText>
                      <Text wrap="break-word">
                        {`${addZeroWidthSpace(groupTitle)} > ${addZeroWidthSpace(searchString)}`}
                      </Text>
                    </TruncateText>
                  ) : (
                    <Text wrap="break-word">
                      {I18n.t('All %{groupTitle} Outcomes', {
                        groupTitle: addZeroWidthSpace(groupTitle)
                      })}
                    </Text>
                  )}
                </Heading>
              </Flex.Item>
              <Flex.Item>
                <Flex as="div" alignItems="center" wrap="wrap">
                  <Flex.Item as="div" padding="x-small medium x-small 0">
                    <Text size="medium">
                      {I18n.t(
                        {
                          one: '%{count} Outcome',
                          other: '%{count} Outcomes'
                        },
                        {
                          count: outcomesCount || 0
                        }
                      )}
                    </Text>
                  </Flex.Item>
                  <Flex.Item>
                    <Button
                      margin="x-small 0"
                      interaction={enabled && !searchString ? 'enabled' : 'disabled'}
                      onClick={onAddAllHandler}
                    >
                      {I18n.t('Add All Outcomes')}
                    </Button>
                  </Flex.Item>
                </Flex>
              </Flex.Item>
            </Flex>
          </View>
        </View>
        <div style={{flex: '1 0 24rem', overflow: 'auto', position: 'relative'}}>
          <InfiniteScroll
            hasMore={outcomes?.pageInfo?.hasNextPage}
            loadMore={loadMore}
            loader={
              // Temp solution until InfiniteScroll is fixed (ticket OUT-4190)
              <Flex
                as="div"
                justifyItems="center"
                alignItems="center"
                padding="medium 0 small"
                shouldGrow
              >
                <Flex.Item>
                  {loading ? (
                    <View as="div" data-testid="load-more-loading">
                      <Spinner renderTitle={I18n.t('Loading')} size="small" />
                    </View>
                  ) : (
                    <Button type="button" color="primary" margin="0 x-small 0 0" onClick={loadMore}>
                      {I18n.t('Load More')}
                    </Button>
                  )}
                </Flex.Item>
              </Flex>
            }
          >
            <View as="div" data-testid="find-outcome-items-list">
              {outcomes?.edges?.map(({node: {_id, title, description, isImported}}, index) => (
                <FindOutcomeItem
                  key={_id}
                  id={_id}
                  title={title}
                  description={description}
                  isFirst={index === 0}
                  isChecked={isImported}
                  onCheckboxHandler={onSelectOutcomesHandler}
                />
              ))}
            </View>
          </InfiniteScroll>
        </div>
      </div>
    </View>
  )
}

FindOutcomesView.propTypes = {
  collection: PropTypes.shape({
    id: PropTypes.string.isRequired,
    name: PropTypes.string.isRequired
  }).isRequired,
  outcomesCount: PropTypes.number.isRequired,
  outcomes: PropTypes.shape({
    edges: PropTypes.arrayOf(
      PropTypes.shape({
        node: PropTypes.shape({
          _id: PropTypes.string.isRequired,
          title: PropTypes.string.isRequired,
          isImported: PropTypes.bool.isRequired,
          description: PropTypes.string
        })
      })
    ),
    pageInfo: PropTypes.shape({
      endCursor: PropTypes.string,
      hasNextPage: PropTypes.bool.isRequired
    })
  }),
  searchString: PropTypes.string.isRequired,
  onChangeHandler: PropTypes.func.isRequired,
  onClearHandler: PropTypes.func.isRequired,
  onAddAllHandler: PropTypes.func.isRequired,
  loading: PropTypes.bool.isRequired,
  loadMore: PropTypes.func.isRequired
}

export default FindOutcomesView
